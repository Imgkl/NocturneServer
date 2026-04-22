import Foundation
import FluentKit
import FluentSQL
import Logging

final class OmdbCacheStore: @unchecked Sendable {
    private let db: Database
    private let logger: Logger
    
    init(db: Database, logger: Logger) {
        self.db = db
        self.logger = logger
    }
    
    func ensureTable() async throws {
        guard let sql = db as? SQLDatabase else { return }
        try await sql.raw("CREATE TABLE IF NOT EXISTS omdb_cache (imdb_id TEXT PRIMARY KEY, ratings_json TEXT NOT NULL, fetched_at INTEGER NOT NULL)").run()
    }
    
    func get(imdbId: String) async throws -> OmdbCacheEntry? {
        guard let sql = db as? SQLDatabase else { return nil }
        if let row = try await sql.raw("SELECT ratings_json, fetched_at FROM omdb_cache WHERE imdb_id = \(bind: imdbId) LIMIT 1").first() {
            let json = try row.decode(column: "ratings_json", as: String.self)
            let ts = try row.decode(column: "fetched_at", as: Int64.self)
            let ratings = try JSONDecoder().decode([OmdbRating].self, from: Data(json.utf8))
            return OmdbCacheEntry(imdbId: imdbId, ratings: ratings, fetchedAt: Date(timeIntervalSince1970: TimeInterval(ts)))
        }
        return nil
    }
    
    func set(imdbId: String, ratings: [OmdbRating]) async throws {
        guard let sql = db as? SQLDatabase else { return }
        let json = String(data: try JSONEncoder().encode(ratings), encoding: .utf8) ?? "[]"
        let ts = Int64(Date().timeIntervalSince1970)
        try await sql.raw("INSERT INTO omdb_cache(imdb_id, ratings_json, fetched_at) VALUES(\(bind: imdbId), \(bind: json), \(bind: ts)) ON CONFLICT(imdb_id) DO UPDATE SET ratings_json=excluded.ratings_json, fetched_at=excluded.fetched_at").run()
    }
}



