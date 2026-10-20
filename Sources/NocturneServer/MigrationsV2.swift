import Foundation
import FluentKit
import FluentSQL

// Tagger rewrite, phase 1 schema. Every ALTER TABLE is guarded by a column check so a
// half-applied migration can be re-run safely (SQLite's ALTER TABLE ADD COLUMN is not idempotent).

/// SQLite column-existence check.
func sqliteColumnExists(_ sql: SQLDatabase, table: String, column: String) async throws -> Bool {
    let rows = try await sql.raw("PRAGMA table_info(\(ident: table))").all()
    for row in rows {
        if try row.decode(column: "name", as: String.self) == column {
            return true
        }
    }
    return false
}

/// Adds a column when it is missing. `definition` is the SQL after the column name.
func sqliteAddColumnIfMissing(_ sql: SQLDatabase, table: String, column: String, definition: String) async throws {
    if try await sqliteColumnExists(sql, table: table, column: column) { return }
    try await sql.raw("ALTER TABLE \(ident: table) ADD COLUMN \(ident: column) \(unsafeRaw: definition)").run()
}

struct CreateTaggerV2Tables: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(MovieEnrichment.schema)
            .field("jellyfin_id", .string, .identifier(auto: false))
            .field("imdb_id", .string)
            .field("tmdb_id", .string)
            .field("wikidata_qid", .string)
            .field("wiki_site", .string)
            .field("wiki_title", .string)
            .field("wiki_title_override", .string)
            .field("identity_json", .string)
            .field("overview_text", .string)
            .field("plot_text", .string)
            .field("reception_text", .string)
            .field("awards_json", .string)
            .field("omdb_awards", .string)
            .field("text_block", .string)
            .field("input_hash", .string)
            .field("source", .string, .required)
            .field("unverified", .bool, .required)
            .field("plot_found", .bool, .required)
            .field("enrich_version", .int, .required)
            .field("jellyfin_last_saved", .string)
            .field("fetched_at", .datetime)
            .field("error", .string)
            .create()

        try await database.schema(Decision.schema)
            .id()
            .field("jellyfin_id", .string, .required)
            .field("run_id", .uuid)
            .field("input_hash", .string)
            .field("enrich_version", .int, .required)
            .field("taxonomy_version", .int, .required)
            .field("guide_version", .int, .required)
            .field("policy_version", .string, .required)
            .field("classifier_provider", .string)
            .field("reader_json", .string)
            .field("classifier_json", .string)
            .field("applied_json", .string, .required)
            .field("suggested_json", .string, .required)
            .field("unsure", .bool, .required)
            .field("outcome", .string, .required)
            .field("reasons_json", .string, .required)
            .field("models_json", .string, .required)
            .field("cost_usd", .double, .required)
            .field("created_at", .datetime)
            .create()

        try await database.schema(ApiCall.schema)
            .id()
            .field("run_id", .uuid)
            .field("decision_id", .uuid)
            .field("provider", .string, .required)
            .field("endpoint", .string, .required)
            .field("model", .string)
            .field("attempt", .int, .required)
            .field("http_status", .int)
            .field("duration_ms", .int, .required)
            .field("units_json", .string, .required)
            .field("cost_usd", .double, .required)
            .field("created_at", .datetime)
            .create()

        try await database.schema(Run.schema)
            .id()
            .field("kind", .string, .required)
            .field("trigger", .string, .required)
            .field("status", .string, .required)
            .field("params_json", .string, .required)
            .field("stats_json", .string, .required)
            .field("cost_json", .string, .required)
            .field("cancel_requested", .bool, .required)
            .field("total", .int, .required)
            .field("processed", .int, .required)
            .field("error", .string)
            .field("started_at", .datetime)
            .field("finished_at", .datetime)
            .field("heartbeat_at", .datetime)
            .create()

        try await database.schema(WikidataLabel.schema)
            .field("qid", .string, .identifier(auto: false))
            .field("label", .string, .required)
            .field("fetched_at", .datetime)
            .create()

        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw("CREATE INDEX IF NOT EXISTS decisions_jellyfin_id_idx ON decisions(jellyfin_id)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS decisions_created_at_idx ON decisions(created_at)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS api_calls_created_at_idx ON api_calls(created_at)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS api_calls_provider_idx ON api_calls(provider)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS api_calls_decision_id_idx ON api_calls(decision_id)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS runs_status_idx ON runs(status)").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema(WikidataLabel.schema).delete()
        try await database.schema(Run.schema).delete()
        try await database.schema(ApiCall.schema).delete()
        try await database.schema(Decision.schema).delete()
        try await database.schema(MovieEnrichment.schema).delete()
    }
}

/// `movie_tags.label_source`: `auto` for rows the tagger wrote, `user` for rows a human wrote.
/// Backfilled from the legacy `added_by_auto_tag` flag.
struct AddLabelSourceToMovieTags: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sqliteAddColumnIfMissing(sql, table: "movie_tags", column: "label_source", definition: "TEXT NOT NULL DEFAULT 'auto'")
        try await sql.raw("UPDATE movie_tags SET label_source = CASE WHEN added_by_auto_tag = 1 THEN 'auto' ELSE 'user' END").run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try? await sql.raw("ALTER TABLE movie_tags DROP COLUMN label_source").run()
    }
}

/// `tag_suggestions.resolved_by`, `decision_id`, `items_json`. Existing resolved rows are
/// retro-labelled in Swift (see `ResolvedBy.infer`) so the stored date format is irrelevant.
struct AddResolvedByToTagSuggestions: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sqliteAddColumnIfMissing(sql, table: "tag_suggestions", column: "resolved_by", definition: "TEXT")
        try await sqliteAddColumnIfMissing(sql, table: "tag_suggestions", column: "decision_id", definition: "TEXT")
        try await sqliteAddColumnIfMissing(sql, table: "tag_suggestions", column: "items_json", definition: "TEXT")

        let rows = try await TagSuggestion.query(on: database).all()
        for row in rows where row.resolvedBy == nil {
            guard let inferred = ResolvedBy.infer(status: row.status, createdAt: row.createdAt, resolvedAt: row.resolvedAt) else {
                continue
            }
            row.resolvedBy = inferred
            try await row.save(on: database)
        }
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try? await sql.raw("ALTER TABLE tag_suggestions DROP COLUMN resolved_by").run()
        try? await sql.raw("ALTER TABLE tag_suggestions DROP COLUMN decision_id").run()
        try? await sql.raw("ALTER TABLE tag_suggestions DROP COLUMN items_json").run()
    }
}

/// `movies.current_decision_id` points at the latest decision row for the film.
struct AddCurrentDecisionToMovies: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sqliteAddColumnIfMissing(sql, table: "movies", column: "current_decision_id", definition: "TEXT")
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try? await sql.raw("ALTER TABLE movies DROP COLUMN current_decision_id").run()
    }
}

/// `movies.played` + `movies.last_played_date`: Jellyfin's per-user watched state, filled on sync.
struct AddPlayedToMovies: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sqliteAddColumnIfMissing(sql, table: "movies", column: "played", definition: "INTEGER NOT NULL DEFAULT 0")
        try await sqliteAddColumnIfMissing(sql, table: "movies", column: "last_played_date", definition: "TEXT")
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try? await sql.raw("ALTER TABLE movies DROP COLUMN played").run()
        try? await sql.raw("ALTER TABLE movies DROP COLUMN last_played_date").run()
    }
}

/// The legacy `SeedMoodTags` list stopped at 34 slugs; `ha-ha-ha` and `emotional-gut-punch` were
/// only created on first use. Inserts every taxonomy slug missing from `tags`, so a fresh install
/// carries all 36 rows before the first film is tagged. Safe to re-run.
struct SeedMissingMoodTags: AsyncMigration {
    func prepare(on database: Database) async throws {
        let taxonomy = try Taxonomy.load()
        let existing = Set(try await Tag.query(on: database).all().map(\.slug))
        for slug in taxonomy.buckets.keys.sorted() where !existing.contains(slug) {
            let bucket = taxonomy.buckets[slug]!
            let shortDescription = bucket.description
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: ". ").first.map { $0.hasSuffix(".") ? $0 : $0 + "." } ?? bucket.title
            try await Tag(slug: slug, title: bucket.title, description: shortDescription, usageCount: 0).save(on: database)
        }
    }

    func revert(on database: Database) async throws {}
}
