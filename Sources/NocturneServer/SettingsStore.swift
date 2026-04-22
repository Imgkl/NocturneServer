import Foundation
import FluentKit
import FluentSQL
import Logging

final class SettingsStore: @unchecked Sendable {
    private let db: Database
    private let logger: Logger
    
    init(db: Database, logger: Logger) {
        self.db = db
        self.logger = logger
    }
    
    // Create a simple key/value table without migrations
    func ensureTable() async throws {
        guard let sql = db as? SQLDatabase else { return }
        try await sql.raw("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)").run()
    }
    
    func set(_ key: String, _ value: String?) async throws {
        guard let sql = db as? SQLDatabase else { return }
        if let v = value {
            try await sql.raw("INSERT INTO settings(key,value) VALUES(\(bind: key), \(bind: v)) ON CONFLICT(key) DO UPDATE SET value=excluded.value").run()
        } else {
            try await sql.raw("DELETE FROM settings WHERE key = \(bind: key)").run()
        }
    }
    
    func get(_ key: String) async throws -> String? {
        guard let sql = db as? SQLDatabase else { return nil }
        if let row = try await sql.raw("SELECT value FROM settings WHERE key = \(bind: key) LIMIT 1").first() {
            return try row.decode(column: "value", as: String.self)
        }
        return nil
    }
    
    func loadAll() async throws -> [String: String] {
        guard let sql = db as? SQLDatabase else { return [:] }
        let rows = try await sql.raw("SELECT key, value FROM settings").all()
        var out: [String: String] = [:]
        for row in rows {
            if let k = try? row.decode(column: "key", as: String.self), let v = try? row.decode(column: "value", as: String.self) {
                out[k] = v
            }
        }
        return out
    }
}


