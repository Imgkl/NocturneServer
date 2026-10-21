import FluentKit
import Foundation
import HummingbirdFluent
import Logging

enum TaggerError: Error, CustomStringConvertible {
    case missingAnthropicKey
    case notFound(UUID)
    case alreadyResolved(UUID)
    case movieNotFound(String)
    case noReaderAnswer(String)

    var description: String {
        switch self {
        case .missingAnthropicKey: return "Anthropic API key is not configured"
        case .notFound(let id): return "Suggestion not found: \(id)"
        case .alreadyResolved(let id): return "Suggestion already resolved: \(id)"
        case .movieNotFound(let id): return "Movie not found: \(id)"
        case .noReaderAnswer(let id): return "No stored reader answer to re-grade: \(id)"
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
    /// Review rows written by `regrade`: the classifier's second look at a tagged film.
    static let regradeKind = "regrade"
    /// Marks an applied item the regrade put on the film (it was not there before), so a reject can take it off again.
    static let addedOnRegrade = "added on regrade"

    let fluent: Fluent
    let config: NocturneConfiguration
    let enrichment: Enriching
    let reader: Reading
    /// The classifier of record; nil when the build has none. Whether it runs is a setting.
    let classifier: DecisionClassifying?
    let movies: MovieService
    let budget: BudgetGuard
    let settings: SettingsStore
    let recorder: DecisionRecorder
    let titles: TitleProvider
    let logger: Logger

    init(
        fluent: Fluent, config: NocturneConfiguration, enrichment: Enriching, reader: Reading, classifier: DecisionClassifying? = nil,
        movies: MovieService, budget: BudgetGuard, settings: SettingsStore, titles: @escaping TitleProvider,
        logger: Logger = Logger(label: "Tagger")
    ) {
        self.fluent = fluent
        self.config = config
        self.enrichment = enrichment
        self.reader = reader
        self.classifier = classifier
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

    func classifierKey() async throws -> String? {
        if let stored = try await settings.get(JevClient.apiKeySetting), !stored.isEmpty { return stored }
        return nil
    }

    /// The classifier of record's answer for a film, or nil with a note when it did not run.
    /// A credentials failure propagates so the run aborts; anything else degrades to the reader.
    private func classify(textBlock: String, jellyfinId: String, policy: PolicyConfig, context: CallContext) async throws -> (ClassifierAnswer?, String?) {
        guard policy.provider != .none else { return (nil, nil) }
        guard let classifier else { return (nil, "classifier \(policy.provider.rawValue) is not built in") }
        guard let key = try await classifierKey() else { return (nil, "classifier key missing") }
        let guide = (try? await GuideStore.full(settings: settings, fallback: config.autoTaggingPrompt)) ?? config.autoTaggingPrompt
        do {
            return (try await classifier.classify(textBlock: textBlock, guide: guide, jellyfinId: jellyfinId, apiKey: key, context: context), nil)
        } catch let error as OutboundError where error.isAuthFailure {
            throw error
        } catch {
            logger.warning("[\(jellyfinId)] classifier failed: \(error)")
            return (nil, "classifier unavailable: \(error)")
        }
    }

    /// The policy decision for a film from the stored answers: p1 with a classifier answer, the
    /// legacy reader-confidence policy without one. A classifier that was expected but did not
    /// answer leaves the film unsure, so nothing it applied escapes review.
    private func decide(reader: ReaderAnswer, classifier: ClassifierAnswer?, note: String?, policy: PolicyConfig, cap: Int, unverified: Bool) -> (PolicyDecision, String) {
        if let classifier {
            let input = PolicyInput(
                candidates: reader.candidates, classifier: classifier, floors: policy.floors, defaultFloor: PolicyConfig.defaultFloor,
                high: policy.high, defaultHigh: PolicyConfig.defaultHigh, maxTags: cap, unverified: unverified)
            return (PolicyEngine.decide(version: policy.version, input: input), policy.version)
        }
        var floors: [String: Double] = [:]
        for (slug, bucket) in config.moodBuckets {
            if let floor = bucket.minConfidence { floors[slug] = floor }
        }
        var decision = PolicyEngine.decide(
            version: PolicyEngine.legacyVersion,
            input: PolicyInput(candidates: reader.candidates, floors: floors, maxTags: cap, unverified: unverified))
        if let note {
            decision = PolicyDecision(
                applied: decision.applied, suggested: decision.suggested, unsure: true,
                outcome: decision.applied.isEmpty ? decision.outcome : .review, reasons: [note] + decision.reasons)
        }
        return (decision, PolicyEngine.legacyVersion)
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
        let learned = try? await GuideStore.learnedText(settings: settings)
        let readerResult: ReaderResult
        do {
            readerResult = try await reader.read(textBlock: textBlock, learnedRules: learned, calibration: cal, apiKey: apiKey, context: context)
        } catch let error as ReaderError {
            try await recorder.complete(decision, with: .init(enrichment: enrichmentRow, reader: nil, policy: .empty, outcome: .error, reasons: [error.description], models: [:]))
            logger.warning("[\(jellyfinId)] reader failed: \(error)")
            return try await writeSuggestion(jellyfinId: jellyfinId, decision: decision, policy: .empty, residue: "auto-tagger failed: \(error.description)", pending: true)
        } catch {
            try await recorder.complete(decision, with: .init(enrichment: enrichmentRow, reader: nil, policy: .empty, outcome: .error, reasons: [String(describing: error)], models: [:]))
            throw error
        }

        // 3. Classifier of record, when one is configured.
        let policyConfig = (try? await PolicyConfig.load(settings: settings, slugs: config.moodBuckets.keys)) ?? PolicyConfig.defaults(slugs: config.moodBuckets.keys)
        let (classifierAnswer, classifierNote) = try await classify(textBlock: textBlock, jellyfinId: jellyfinId, policy: policyConfig, context: context)

        // 4. Policy. The admin's own tags count against the cap.
        let cap = max(0, config.maxAutoTags - (try await movies.userTagCount(jellyfinId: jellyfinId)))
        let (policy, policyVersion) = decide(reader: readerResult.answer, classifier: classifierAnswer, note: classifierNote, policy: policyConfig, cap: cap, unverified: unverified)

        // 5. Apply, then record.
        if !policy.applied.isEmpty {
            _ = try await movies.updateMovieTags(jellyfinId: jellyfinId, tagSlugs: policy.applied.map(\.slug), replaceAll: false, labelSource: .auto)
        }
        try await recorder.complete(
            decision,
            with: .init(enrichment: enrichmentRow, reader: readerResult, classifier: classifierAnswer, policy: policy, outcome: policy.outcome, reasons: policy.reasons, models: [:], policyVersion: policyVersion))

        let pending = policy.outcome != .applied
        logger.info("[\(jellyfinId)] \(policy.outcome.rawValue): applied \(policy.applied.map(\.slug)), suggested \(policy.suggested.map(\.slug)), cost $\(Self.money(decision.costUsd))")
        return try await writeSuggestion(jellyfinId: jellyfinId, decision: decision, policy: policy, residue: readerResult.answer.residue, pending: pending)
    }

    /// Classifier-only pass over a film whose reader answer is already stored: the current
    /// decision's reader answer is reused, the classifier runs fresh, the policy decides again.
    /// Additions follow the policy; a mood the tagger applied earlier that the new decision does
    /// not apply is reported as a removal item, never removed.
    @discardableResult
    func regrade(jellyfinId: String, trigger: RunTrigger, runId: UUID? = nil) async throws -> TagSuggestion {
        let db = fluent.db()
        guard let movie = try await Movie.query(on: db).filter(\.$jellyfinId == jellyfinId).with(\.$tags).first() else {
            throw TaggerError.movieNotFound(jellyfinId)
        }
        guard let currentId = movie.currentDecisionId, let previous = try await Decision.find(currentId, on: db), let readerJson = previous.readerJson else {
            throw TaggerError.noReaderAnswer(jellyfinId)
        }
        let readerAnswer = try ReaderService.parse(readerJson, knownSlugs: Set(config.moodBuckets.keys), maxTags: config.maxAutoTags, logger: logger)

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
        decision.readerJson = readerJson
        let context = CallContext(runId: runId, decisionId: decision.id)
        let enrichmentRow = try await enrichment.enrich(jellyfinId: jellyfinId, item: nil, force: false, context: context)
        let textBlock = enrichmentRow.textBlock ?? Self.fallbackBlock(from: enrichmentRow)
        let unverified = enrichmentRow.enrichmentSource == .model

        let policyConfig = (try? await PolicyConfig.load(settings: settings, slugs: config.moodBuckets.keys)) ?? PolicyConfig.defaults(slugs: config.moodBuckets.keys)
        let (classifierAnswer, classifierNote) = try await classify(textBlock: textBlock, jellyfinId: jellyfinId, policy: policyConfig, context: context)
        let cap = max(0, config.maxAutoTags - (try await movies.userTagCount(jellyfinId: jellyfinId)))
        let (policy, policyVersion) = decide(reader: readerAnswer, classifier: classifierAnswer, note: classifierNote, policy: policyConfig, cap: cap, unverified: unverified)

        // Pending rows for the film are superseded; the tagger's own earlier tags stay in place.
        let pending = try await TagSuggestion.query(on: db).filter(\.$jellyfinId == jellyfinId).filter(\.$status == "pending").all()
        for old in pending {
            old.status = "superseded"
            old.resolvedAt = Date()
            try await old.save(on: db)
        }
        let before = Set(movie.tags.map(\.slug))
        let autoBefore = Set(try await movies.autoTagSlugs(jellyfinId: jellyfinId))
        if !policy.applied.isEmpty {
            _ = try await movies.updateMovieTags(jellyfinId: jellyfinId, tagSlugs: policy.applied.map(\.slug), replaceAll: false, labelSource: .auto)
        }
        let keptBySystem = Set(policy.applied.map(\.slug))
        let removals = autoBefore.filter { !keptBySystem.contains($0) }.sorted()
        let added = keptBySystem.subtracting(before)
        var reasons = policy.reasons
        for slug in removals { reasons.append("\(slug): removal suggested, the new decision does not apply it") }
        try await recorder.complete(
            decision,
            with: .init(enrichment: enrichmentRow, reader: nil, classifier: classifierAnswer, policy: policy, outcome: policy.outcome, reasons: reasons, models: ["regrade": "true"], policyVersion: policyVersion))
        let needsHuman = policy.outcome != .applied || !removals.isEmpty
        logger.info("[\(jellyfinId)] regrade \(policy.outcome.rawValue): applied \(policy.applied.map(\.slug)), suggested \(policy.suggested.map(\.slug)), removals \(removals)")
        return try await writeSuggestion(jellyfinId: jellyfinId, decision: decision, policy: policy, residue: readerAnswer.residue, pending: needsHuman, regrade: (removals: removals, added: added))
    }

    // MARK: Helpers

    /// A regrade row marks what it put on the film (so a reject can undo it) and lists the moods it would drop.
    private func writeSuggestion(jellyfinId: String, decision: Decision, policy: PolicyDecision, residue: String?, pending: Bool, regrade: (removals: [String], added: Set<String>)? = nil) async throws -> TagSuggestion {
        var items = DecisionRecorder.items(from: policy)
        if let regrade {
            items = items.map { item in
                guard item.kind == .add, item.applied, regrade.added.contains(item.slug) else { return item }
                return SuggestionItem(slug: item.slug, probability: item.probability, evidence: item.evidence, kind: .add, applied: true, reason: Self.addedOnRegrade)
            }
            items += regrade.removals.map { SuggestionItem(slug: $0, probability: 0, evidence: nil, kind: .remove, applied: true, reason: "the new decision does not apply it") }
        }
        let sugg = TagSuggestion(
            jellyfinId: jellyfinId,
            suggestedTags: policy.applied.map(\.slug),
            confidence: policy.applied.map(\.probability).min() ?? 0,
            reasoning: residue,
            status: pending ? "pending" : "approved",
            kind: regrade == nil ? "additive" : Self.regradeKind)
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
