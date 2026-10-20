import Foundation
import FluentKit
import FluentSQL
import Logging
import Testing

@testable import NocturneServer

// MARK: - Legacy row shapes (pre-phase-1 schema), used to seed a database before the new migrations run.

private final class LegacyMovie: Model, @unchecked Sendable {
    static let schema = "movies"
    @ID(key: .id) var id: UUID?
    @Field(key: "jellyfin_id") var jellyfinId: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
    init(jellyfinId: String) { self.jellyfinId = jellyfinId }
}

private final class LegacyMovieTag: Model, @unchecked Sendable {
    static let schema = "movie_tags"
    @ID(key: .id) var id: UUID?
    @Field(key: "movie_id") var movieId: UUID
    @Field(key: "tag_id") var tagId: UUID
    @Field(key: "added_by_auto_tag") var addedByAutoTag: Bool
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
    init(movieId: UUID, tagId: UUID, addedByAutoTag: Bool) {
        self.movieId = movieId
        self.tagId = tagId
        self.addedByAutoTag = addedByAutoTag
    }
}

private final class LegacyTagSuggestion: Model, @unchecked Sendable {
    static let schema = "tag_suggestions"
    @ID(key: .id) var id: UUID?
    @Field(key: "jellyfin_id") var jellyfinId: String
    @Field(key: "suggested_tags") var suggestedTags: [String]
    @Field(key: "confidence") var confidence: Double
    @Field(key: "status") var status: String
    @Field(key: "kind") var kind: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @OptionalField(key: "resolved_at") var resolvedAt: Date?
    init() {}
    init(jellyfinId: String, status: String) {
        self.jellyfinId = jellyfinId
        self.suggestedTags = ["ha-ha-ha"]
        self.confidence = 0.9
        self.status = status
        self.kind = "additive"
    }
}

@Suite struct MigrationTests {

    @Test func newTablesAcceptRows() async throws {
        try await withTestFluent { fluent in
            let db = fluent.db()

            let enrichment = MovieEnrichment(jellyfinId: "jf-1")
            enrichment.plotText = "A thief and a cop."
            try await enrichment.save(on: db)

            let decision = Decision(jellyfinId: "jf-1", policyVersion: "p-legacy", outcome: "applied")
            try await decision.save(on: db)

            let call = ApiCall(
                runId: nil, decisionId: decision.id, provider: "anthropic", endpoint: "/v1/messages",
                model: "claude-haiku-5-5", attempt: 1, httpStatus: 200, durationMs: 420,
                unitsJson: "{\"inputTokens\":1000}", costUsd: 0.0001)
            try await call.save(on: db)

            let run = Run(kind: "enrich-coverage", trigger: "manual", total: 10)
            try await run.save(on: db)

            try await WikidataLabel(qid: "Q102427", label: "Academy Award for Best Picture").save(on: db)

            let loaded = try await MovieEnrichment.find("jf-1", on: db)
            #expect(loaded?.plotText == "A thief and a cop.")
            #expect(loaded?.source == "none")
            #expect(try await Decision.query(on: db).count() == 1)
            #expect(try await ApiCall.query(on: db).filter(\.$decisionId == decision.id).count() == 1)
            #expect(try await Run.query(on: db).filter(\.$status == "running").count() == 1)
            #expect(try await WikidataLabel.find("Q102427", on: db)?.label == "Academy Award for Best Picture")
        }
    }

    @Test func labelSourceBackfillsFromLegacyFlag() async throws {
        try await withLegacyFluent { fluent in
            let db = fluent.db()

            let movie = LegacyMovie(jellyfinId: "jf-1")
            try await movie.save(on: db)
            // Note: the legacy seed migration lacks `ha-ha-ha` and `emotional-gut-punch` (they were
            // added to Configuration later and get created on first use). Task 16 fixes the seed.
            let tagA = try #require(try await Tag.query(on: db).filter(\.$slug == "heist-energy").first())
            let tagB = try #require(try await Tag.query(on: db).filter(\.$slug == "cult-chaos").first())
            let movieId = try movie.requireID()
            try await LegacyMovieTag(movieId: movieId, tagId: try tagA.requireID(), addedByAutoTag: true).save(on: db)
            try await LegacyMovieTag(movieId: movieId, tagId: try tagB.requireID(), addedByAutoTag: false).save(on: db)

            try await applyTaggerV2(fluent)

            let rows = try await MovieTag.query(on: db).with(\.$tag).all()
            let bySlug = Dictionary(uniqueKeysWithValues: rows.map { ($0.tag.slug, $0.labelSource) })
            #expect(bySlug["heist-energy"] == "auto")
            #expect(bySlug["cult-chaos"] == "user")
        }
    }

    @Test func resolvedByIsInferredFromTimingAndStatus() async throws {
        try await withLegacyFluent { fluent in
            let db = fluent.db()

            let autoApproved = LegacyTagSuggestion(jellyfinId: "auto", status: "approved")
            try await autoApproved.save(on: db)
            autoApproved.resolvedAt = autoApproved.createdAt
            try await autoApproved.save(on: db)

            let humanApproved = LegacyTagSuggestion(jellyfinId: "human", status: "approved")
            try await humanApproved.save(on: db)
            humanApproved.resolvedAt = try #require(humanApproved.createdAt).addingTimeInterval(90)
            try await humanApproved.save(on: db)

            let rejected = LegacyTagSuggestion(jellyfinId: "rejected", status: "rejected")
            try await rejected.save(on: db)
            rejected.resolvedAt = try #require(rejected.createdAt).addingTimeInterval(5)
            try await rejected.save(on: db)

            let pending = LegacyTagSuggestion(jellyfinId: "pending", status: "pending")
            try await pending.save(on: db)

            try await applyTaggerV2(fluent)

            let rows = try await TagSuggestion.query(on: db).all()
            func resolvedBy(_ film: String) throws -> String? {
                try #require(rows.first { $0.jellyfinId == film }).resolvedBy
            }
            #expect(try resolvedBy("auto") == "auto")
            #expect(try resolvedBy("human") == "user")
            #expect(try resolvedBy("rejected") == "user")
            #expect(try resolvedBy("pending") == nil)
        }
    }

    @Test func inferenceRuleEdgeCases() {
        let now = Date()
        #expect(ResolvedBy.infer(status: "approved", createdAt: now, resolvedAt: now.addingTimeInterval(1.9)) == "auto")
        #expect(ResolvedBy.infer(status: "approved", createdAt: now, resolvedAt: now.addingTimeInterval(2.1)) == "user")
        #expect(ResolvedBy.infer(status: "approved", createdAt: nil, resolvedAt: now) == "user")
        #expect(ResolvedBy.infer(status: "rejected", createdAt: now, resolvedAt: now) == "user")
        #expect(ResolvedBy.infer(status: "superseded", createdAt: now, resolvedAt: now) == nil)
        #expect(ResolvedBy.infer(status: "pending", createdAt: now, resolvedAt: nil) == nil)
    }

    @Test func migrationsAreRerunnable() async throws {
        try await withLegacyFluent { fluent in
            // Simulate a half-applied state: some columns exist but the migration never recorded.
            let db = fluent.db()
            let sql = try #require(db as? SQLDatabase)
            try await sql.raw("ALTER TABLE movie_tags ADD COLUMN label_source TEXT NOT NULL DEFAULT 'auto'").run()
            try await sql.raw("ALTER TABLE tag_suggestions ADD COLUMN resolved_by TEXT").run()

            try await applyTaggerV2(fluent)

            #expect(try await sqliteColumnExists(sql, table: "tag_suggestions", column: "items_json"))
            #expect(try await sqliteColumnExists(sql, table: "movies", column: "current_decision_id"))
        }
    }

    @Test func omdbCacheGainsAwardsColumnAndRoundTrips() async throws {
        try await withTestFluent { fluent in
            let db = fluent.db()
            let sql = try #require(db as? SQLDatabase)
            // Pre-existing table from an older release, without `awards`.
            try await sql.raw("CREATE TABLE IF NOT EXISTS omdb_cache (imdb_id TEXT PRIMARY KEY, ratings_json TEXT NOT NULL, fetched_at INTEGER NOT NULL)").run()
            try await sql.raw("INSERT INTO omdb_cache(imdb_id, ratings_json, fetched_at) VALUES('tt0000001', '[]', 1)").run()

            let store = OmdbCacheStore(db: db, logger: Logger(label: "test"))
            try await store.ensureTable()
            try await store.ensureTable()  // idempotent

            let legacy = try await store.get(imdbId: "tt0000001")
            #expect(legacy?.awards == nil)

            try await store.set(
                imdbId: "tt0113277",
                ratings: [OmdbRating(Source: "Internet Movie Database", Value: "8.3/10")],
                awards: "Nominated for 1 BAFTA Award. 12 wins & 15 nominations total")
            let entry = try await store.get(imdbId: "tt0113277")
            #expect(entry?.awards == "Nominated for 1 BAFTA Award. 12 wins & 15 nominations total")
            #expect(entry?.ratings.first?.Value == "8.3/10")
        }
    }
}
