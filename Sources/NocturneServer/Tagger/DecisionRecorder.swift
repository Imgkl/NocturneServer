import FluentKit
import Foundation
import HummingbirdFluent
import Logging

/// One item of a suggestion row's `items_json`: what the review UI renders per mood.
struct SuggestionItem: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case add
        case remove
    }
    let slug: String
    let probability: Double
    let evidence: String?
    let kind: Kind
    /// Whether the tag is on the film right now (applied) or only proposed.
    let applied: Bool
    let reason: String?
}

/// Writes and completes `decisions` rows and points `movies.current_decision_id` at them.
/// A row is opened before any model call so `api_calls` can carry its id, then completed with
/// the layers' raw answers, the policy outcome and the summed cost.
final class DecisionRecorder: Sendable {
    static let taxonomyVersion = 1
    static let guideVersion = 0

    let fluent: Fluent
    let logger: Logger

    init(fluent: Fluent, logger: Logger = Logger(label: "Decisions")) {
        self.fluent = fluent
        self.logger = logger
    }

    /// Opens a row with outcome `error`, so a crash mid-pipeline leaves an honest record.
    func begin(jellyfinId: String, runId: UUID?, policyVersion: String) async throws -> Decision {
        let decision = Decision(jellyfinId: jellyfinId, policyVersion: policyVersion, outcome: PolicyDecision.Outcome.error.rawValue)
        decision.runId = runId
        decision.taxonomyVersion = Self.taxonomyVersion
        decision.guideVersion = Self.guideVersion
        decision.reasonsJson = Self.json(["opened"])
        try await decision.save(on: fluent.db())
        return decision
    }

    struct Completion: Sendable {
        var enrichment: MovieEnrichment?
        var reader: ReaderResult?
        var policy: PolicyDecision
        var outcome: PolicyDecision.Outcome
        var reasons: [String]
        var models: [String: String]
    }

    /// Fills the row in, sums the cost of every call that carried its id, and makes it the film's
    /// current decision.
    @discardableResult
    func complete(_ decision: Decision, with completion: Completion) async throws -> Decision {
        let db = fluent.db()
        decision.inputHash = completion.enrichment?.inputHash
        decision.enrichVersion = completion.enrichment?.enrichVersion ?? 0
        decision.readerJson = completion.reader?.rawJson
        decision.appliedJson = Self.json(completion.policy.applied)
        decision.suggestedJson = Self.json(completion.policy.suggested)
        decision.unsure = completion.policy.unsure
        decision.outcome = completion.outcome.rawValue
        decision.reasonsJson = Self.json(completion.reasons)
        var models = completion.models
        models["enrichment_source"] = completion.enrichment?.source ?? EnrichmentSource.none.rawValue
        if let reader = completion.reader { models["reader"] = reader.model }
        decision.modelsJson = Self.json(models)
        if let id = decision.id {
            let calls = try await ApiCall.query(on: db).filter(\.$decisionId == id).all()
            decision.costUsd = calls.reduce(0) { $0 + $1.costUsd }
        }
        try await decision.save(on: db)

        if let id = decision.id, let movie = try await Movie.query(on: db).filter(\.$jellyfinId == decision.jellyfinId).first() {
            movie.currentDecisionId = id
            try await movie.save(on: db)
        }
        return decision
    }

    /// Items for the suggestion row: applied moods first, then proposed ones.
    static func items(from policy: PolicyDecision) -> [SuggestionItem] {
        policy.applied.map { SuggestionItem(slug: $0.slug, probability: $0.probability, evidence: $0.evidence, kind: .add, applied: true, reason: nil) }
            + policy.suggested.map { SuggestionItem(slug: $0.slug, probability: $0.probability, evidence: $0.evidence, kind: .add, applied: false, reason: $0.reason) }
    }

    static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}
