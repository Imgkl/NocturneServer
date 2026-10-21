import Foundation
import FluentKit

// MARK: - Label provenance

/// Who put a mood on a film. `seed` is the import path, `auto` the tagger, `user` the admin.
enum LabelSource: String, Codable, Sendable {
    case seed
    case auto
    case user
}

/// Who resolved a suggestion row. Rows the tagger auto-approved at creation are `auto`;
/// rows a human approved, edited or rejected are `user`.
enum ResolvedBy {
    static let auto = "auto"
    static let user = "user"

    /// Retro-labels a legacy `tag_suggestions` row. Auto rows were written as `approved`
    /// with `resolved_at` set in the same instant as `created_at`; anything resolved by a
    /// human came at least seconds later. Pending and superseded rows stay unresolved.
    static func infer(status: String, createdAt: Date?, resolvedAt: Date?) -> String? {
        switch status {
        case "approved":
            if let c = createdAt, let r = resolvedAt, r.timeIntervalSince(c) < 2 {
                return auto
            }
            return user
        case "rejected":
            return user
        default:
            return nil
        }
    }
}

// MARK: - Enrichment (classifier input per film)

enum EnrichmentSource: String, Codable, Sendable {
    case wikipedia
    case wikipediaOtherLang = "wikipedia_other_lang"
    case model
    case none
}

/// Per-film story source: the resolved page, the fetched plot and reception text, structured
/// awards, the canonical text block every model reads, and its hash. Classifier input only;
/// client endpoints never return any of it.
final class MovieEnrichment: Model, @unchecked Sendable {
    static let schema = "movie_enrichment"

    @ID(custom: "jellyfin_id", generatedBy: .user)
    var id: String?

    @OptionalField(key: "imdb_id") var imdbId: String?
    @OptionalField(key: "tmdb_id") var tmdbId: String?
    @OptionalField(key: "wikidata_qid") var wikidataQid: String?
    @OptionalField(key: "wiki_site") var wikiSite: String?
    @OptionalField(key: "wiki_title") var wikiTitle: String?
    @OptionalField(key: "wiki_title_override") var wikiTitleOverride: String?
    @OptionalField(key: "identity_json") var identityJson: String?
    @OptionalField(key: "overview_text") var overviewText: String?
    @OptionalField(key: "plot_text") var plotText: String?
    @OptionalField(key: "reception_text") var receptionText: String?
    @OptionalField(key: "lead_text") var leadText: String?
    @OptionalField(key: "awards_json") var awardsJson: String?
    @OptionalField(key: "omdb_awards") var omdbAwards: String?
    @OptionalField(key: "text_block") var textBlock: String?
    @OptionalField(key: "input_hash") var inputHash: String?
    @Field(key: "source") var source: String
    @Field(key: "unverified") var unverified: Bool
    @Field(key: "plot_found") var plotFound: Bool
    @Field(key: "enrich_version") var enrichVersion: Int
    @OptionalField(key: "jellyfin_last_saved") var jellyfinLastSaved: String?
    @OptionalField(key: "fetched_at") var fetchedAt: Date?
    @OptionalField(key: "error") var error: String?

    init() {}

    init(jellyfinId: String) {
        self.id = jellyfinId
        self.source = EnrichmentSource.none.rawValue
        self.unverified = false
        self.plotFound = false
        self.enrichVersion = 0
    }

    var jellyfinId: String { id ?? "" }
    var enrichmentSource: EnrichmentSource { EnrichmentSource(rawValue: source) ?? .none }
}

// MARK: - Decision record

/// One classification attempt for one film: every layer's raw answer, the versions that
/// produced it, the policy outcome and its cost. Policies replay over these rows.
final class Decision: Model, @unchecked Sendable {
    static let schema = "decisions"

    @ID(key: .id) var id: UUID?
    @Field(key: "jellyfin_id") var jellyfinId: String
    @OptionalField(key: "run_id") var runId: UUID?
    @OptionalField(key: "input_hash") var inputHash: String?
    @Field(key: "enrich_version") var enrichVersion: Int
    @Field(key: "taxonomy_version") var taxonomyVersion: Int
    @Field(key: "guide_version") var guideVersion: Int
    @Field(key: "policy_version") var policyVersion: String
    @OptionalField(key: "classifier_provider") var classifierProvider: String?
    @OptionalField(key: "reader_json") var readerJson: String?
    @OptionalField(key: "classifier_json") var classifierJson: String?
    @Field(key: "applied_json") var appliedJson: String
    @Field(key: "suggested_json") var suggestedJson: String
    @Field(key: "unsure") var unsure: Bool
    /// `applied`, `review`, `none`, `error`, `skipped`
    @Field(key: "outcome") var outcome: String
    @Field(key: "reasons_json") var reasonsJson: String
    @Field(key: "models_json") var modelsJson: String
    @Field(key: "cost_usd") var costUsd: Double
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(jellyfinId: String, policyVersion: String, outcome: String) {
        self.jellyfinId = jellyfinId
        self.enrichVersion = 0
        self.taxonomyVersion = 0
        self.guideVersion = 0
        self.policyVersion = policyVersion
        self.appliedJson = "[]"
        self.suggestedJson = "[]"
        self.unsure = false
        self.outcome = outcome
        self.reasonsJson = "[]"
        self.modelsJson = "{}"
        self.costUsd = 0
    }
}

// MARK: - Outbound call metering

/// One attempt of one outbound HTTP call. Never stores bodies, headers or keys.
final class ApiCall: Model, @unchecked Sendable {
    static let schema = "api_calls"

    @ID(key: .id) var id: UUID?
    @OptionalField(key: "run_id") var runId: UUID?
    @OptionalField(key: "decision_id") var decisionId: UUID?
    @Field(key: "provider") var provider: String
    @Field(key: "endpoint") var endpoint: String
    @OptionalField(key: "model") var model: String?
    @Field(key: "attempt") var attempt: Int
    @OptionalField(key: "http_status") var httpStatus: Int?
    @Field(key: "duration_ms") var durationMs: Int
    @Field(key: "units_json") var unitsJson: String
    @Field(key: "cost_usd") var costUsd: Double
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(
        runId: UUID?, decisionId: UUID?, provider: String, endpoint: String, model: String?,
        attempt: Int, httpStatus: Int?, durationMs: Int, unitsJson: String, costUsd: Double
    ) {
        self.runId = runId
        self.decisionId = decisionId
        self.provider = provider
        self.endpoint = endpoint
        self.model = model
        self.attempt = attempt
        self.httpStatus = httpStatus
        self.durationMs = durationMs
        self.unitsJson = unitsJson
        self.costUsd = costUsd
    }
}

// MARK: - Long-running jobs

/// A persisted job (`backfill`, `reprocess`, `regrade`, `eval`, `enrich-coverage`, `teach`).
/// Progress and cancellation live here, so a restart never loses them.
final class Run: Model, @unchecked Sendable {
    static let schema = "runs"

    @ID(key: .id) var id: UUID?
    @Field(key: "kind") var kind: String
    @Field(key: "trigger") var trigger: String
    /// `running`, `done`, `cancelled`, `error`
    @Field(key: "status") var status: String
    @Field(key: "params_json") var paramsJson: String
    @Field(key: "stats_json") var statsJson: String
    @Field(key: "cost_json") var costJson: String
    @Field(key: "cancel_requested") var cancelRequested: Bool
    @Field(key: "total") var total: Int
    @Field(key: "processed") var processed: Int
    @OptionalField(key: "error") var error: String?
    @OptionalField(key: "started_at") var startedAt: Date?
    @OptionalField(key: "finished_at") var finishedAt: Date?
    @OptionalField(key: "heartbeat_at") var heartbeatAt: Date?

    init() {}

    init(kind: String, trigger: String, total: Int, paramsJson: String = "{}") {
        self.kind = kind
        self.trigger = trigger
        self.status = "running"
        self.paramsJson = paramsJson
        self.statsJson = "{}"
        self.costJson = "{}"
        self.cancelRequested = false
        self.total = total
        self.processed = 0
        let now = Date()
        self.startedAt = now
        self.heartbeatAt = now
    }
}

// MARK: - Wikidata label cache

final class WikidataLabel: Model, @unchecked Sendable {
    static let schema = "wikidata_labels"

    @ID(custom: "qid", generatedBy: .user) var id: String?
    @Field(key: "label") var label: String
    @OptionalField(key: "fetched_at") var fetchedAt: Date?

    init() {}

    init(qid: String, label: String) {
        self.id = qid
        self.label = label
        self.fetchedAt = Date()
    }
}
