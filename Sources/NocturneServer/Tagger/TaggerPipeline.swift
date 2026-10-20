import FluentKit
import Foundation
import HummingbirdFluent
import Logging

enum TaggerError: Error, CustomStringConvertible {
    case missingAnthropicKey
    case notFound(UUID)
    case alreadyResolved(UUID)
    case movieNotFound(String)

    var description: String {
        switch self {
        case .missingAnthropicKey: return "Anthropic API key is not configured"
        case .notFound(let id): return "Suggestion not found: \(id)"
        case .alreadyResolved(let id): return "Suggestion already resolved: \(id)"
        case .movieNotFound(let id): return "Movie not found: \(id)"
        }
    }
}

/// Seam over `ReaderService` for tests.
protocol Reading: Sendable {
    func read(textBlock: String, learnedRules: String?, calibration: [String: TagCalibration], apiKey: String, context: CallContext) async throws -> ReaderResult
}

extension ReaderService: Reading {}

/// Titles for calibration lines; production reads them from Jellyfin once per run.
typealias TitleProvider = @Sendable () async -> [String: String]

/// The one entry point for tagging a film: budget check, enrich, read, decide, record, apply,
/// write the review row. Realtime, the manual route and the backfill job all come through here.
final class TaggerPipeline: @unchecked Sendable {
    static let apiKeySetting = "anthropic_api_key"

    let fluent: Fluent
    let config: NocturneConfiguration
    let enrichment: Enriching
    let reader: Reading
    let movies: MovieService
    let budget: BudgetGuard
    let settings: SettingsStore
    let recorder: DecisionRecorder
    let titles: TitleProvider
    let logger: Logger

    init(
        fluent: Fluent, config: NocturneConfiguration, enrichment: Enriching, reader: Reading, movies: MovieService,
        budget: BudgetGuard, settings: SettingsStore, titles: @escaping TitleProvider,
        logger: Logger = Logger(label: "Tagger")
    ) {
        self.fluent = fluent
        self.config = config
        self.enrichment = enrichment
        self.reader = reader
        self.movies = movies
        self.budget = budget
        self.settings = settings
        self.recorder = DecisionRecorder(fluent: fluent, taxonomyVersion: config.taxonomyVersion, logger: logger)
        self.titles = titles
        self.logger = logger
    }

    func apiKey() async throws -> String? {
        if let stored = try await settings.get(Self.apiKeySetting), !stored.isEmpty { return stored }
        if let fromConfig = config.anthropicApiKey, !fromConfig.isEmpty { return fromConfig }
        return nil
    }

    /// Fire-and-forget wrapper for the realtime hook.
    func tagInBackground(jellyfinId: String, trigger: RunTrigger) {
        Task { [weak self] in
            do {
                _ = try await self?.tag(jellyfinId: jellyfinId, trigger: trigger)
            } catch {
                self?.logger.warning("Background tagging failed for \(jellyfinId): \(error)")
            }
        }
    }

    /// Tags one film and returns its review row. An existing pending row short-circuits unless
    /// `replaceExistingPending`, in which case it is superseded.
    @discardableResult
    func tag(
        jellyfinId: String, trigger: RunTrigger, replaceExistingPending: Bool = false,
        calibration: [String: TagCalibration]? = nil, runId: UUID? = nil
    ) async throws -> TagSuggestion {
        let db = fluent.db()

        let existing = try await TagSuggestion.query(on: db)
            .filter(\.$jellyfinId == jellyfinId)
            .filter(\.$status == "pending")
            .all()
        if !existing.isEmpty {
            if !replaceExistingPending { return existing[0] }
            for old in existing {
                old.status = "superseded"
                old.resolvedAt = Date()
                try await old.save(on: db)
            }
        }

        guard let apiKey = try await apiKey() else { throw TaggerError.missingAnthropicKey }

        let verdict = try await budget.allow(trigger)
        guard verdict.allowed else {
            if case .paused(let spent, let cap) = verdict {
                let reason = "budget cap reached: $\(Self.money(spent)) of $\(Self.money(cap)) this month"
                let decision = try await recorder.begin(jellyfinId: jellyfinId, runId: runId, policyVersion: PolicyEngine.legacyVersion)
                try await recorder.complete(decision, with: .init(enrichment: nil, reader: nil, policy: .empty, outcome: .skipped, reasons: [reason], models: [:]))
                return try await writeSuggestion(jellyfinId: jellyfinId, decision: decision, policy: .empty, residue: reason, pending: true)
            }
            throw TaggerError.missingAnthropicKey
        }

        let decision = try await recorder.begin(jellyfinId: jellyfinId, runId: runId, policyVersion: PolicyEngine.legacyVersion)
        let context = CallContext(runId: runId, decisionId: decision.id)

        // 1. Story source.
        let enrichmentRow = try await enrichment.enrich(jellyfinId: jellyfinId, item: nil, force: false, context: context)
        let textBlock = enrichmentRow.textBlock ?? Self.fallbackBlock(from: enrichmentRow)
        let unverified = enrichmentRow.enrichmentSource == .model

        // 2. Reader.
        let cal: [String: TagCalibration]
        if let calibration {
            cal = calibration
        } else {
            cal = (try? await buildCalibration(fluent: fluent, titles: await titles(), availableTags: config.moodBuckets)) ?? [:]
        }
        let readerResult: ReaderResult
        do {
            readerResult = try await reader.read(textBlock: textBlock, learnedRules: nil, calibration: cal, apiKey: apiKey, context: context)
        } catch let error as ReaderError {
            try await recorder.complete(decision, with: .init(enrichment: enrichmentRow, reader: nil, policy: .empty, outcome: .error, reasons: [error.description], models: [:]))
            logger.warning("[\(jellyfinId)] reader failed: \(error)")
            return try await writeSuggestion(jellyfinId: jellyfinId, decision: decision, policy: .empty, residue: "auto-tagger failed: \(error.description)", pending: true)
        } catch {
            try await recorder.complete(decision, with: .init(enrichment: enrichmentRow, reader: nil, policy: .empty, outcome: .error, reasons: [String(describing: error)], models: [:]))
            throw error
        }

        // 3. Policy. The admin's own tags count against the cap.
        var floors: [String: Double] = [:]
        for (slug, bucket) in config.moodBuckets {
            if let floor = bucket.minConfidence { floors[slug] = floor }
        }
        let cap = max(0, config.maxAutoTags - (try await movies.userTagCount(jellyfinId: jellyfinId)))
        let policy = PolicyEngine.decide(
            version: PolicyEngine.legacyVersion,
            input: PolicyInput(candidates: readerResult.answer.candidates, floors: floors, maxTags: cap, unverified: unverified))

        // 4. Apply, then record.
        if !policy.applied.isEmpty {
            _ = try await movies.updateMovieTags(jellyfinId: jellyfinId, tagSlugs: policy.applied.map(\.slug), replaceAll: false, labelSource: .auto)
        }
        try await recorder.complete(
            decision,
            with: .init(enrichment: enrichmentRow, reader: readerResult, policy: policy, outcome: policy.outcome, reasons: policy.reasons, models: [:]))

        let pending = policy.outcome != .applied
        logger.info("[\(jellyfinId)] \(policy.outcome.rawValue): applied \(policy.applied.map(\.slug)), suggested \(policy.suggested.map(\.slug)), cost $\(Self.money(decision.costUsd))")
        return try await writeSuggestion(jellyfinId: jellyfinId, decision: decision, policy: policy, residue: readerResult.answer.residue, pending: pending)
    }

    // MARK: Helpers

    private func writeSuggestion(jellyfinId: String, decision: Decision, policy: PolicyDecision, residue: String?, pending: Bool) async throws -> TagSuggestion {
        let items = DecisionRecorder.items(from: policy)
        let sugg = TagSuggestion(
            jellyfinId: jellyfinId,
            suggestedTags: policy.applied.map(\.slug),
            confidence: policy.applied.map(\.probability).min() ?? 0,
            reasoning: residue,
            status: pending ? "pending" : "approved")
        sugg.decisionId = decision.id
        sugg.itemsJson = DecisionRecorder.json(items)
        if !pending {
            sugg.resolvedAt = Date()
            sugg.resolvedBy = ResolvedBy.auto
        }
        try await sugg.save(on: fluent.db())
        return sugg
    }

    /// When enrichment has no block at all (Jellyfin reachable, every story source failed), the
    /// reader still gets the identity and overview, which is what today's tagger reads.
    static func fallbackBlock(from row: MovieEnrichment) -> String {
        var input = TextBlockInput(title: row.jellyfinId, fetchedOn: EnrichmentService.dayString(Date()))
        if let json = row.identityJson, let identity = try? JSONDecoder().decode(EnrichmentService.Identity.self, from: Data(json.utf8)) {
            input.title = identity.title
            input.originalTitle = identity.originalTitle
            input.year = identity.year
            input.director = identity.director
            input.runtimeMinutes = identity.runtimeMinutes
            input.genres = identity.genres
            input.cast = identity.cast
            input.overview = identity.overview
        } else {
            input.overview = row.overviewText
        }
        return TextBlockBuilder.build(input).block
    }

    static func money(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}
