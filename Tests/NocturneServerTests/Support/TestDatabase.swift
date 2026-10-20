import Foundation
import FluentKit
import FluentSQLiteDriver
import HummingbirdFluent
import Logging

@testable import NocturneServer

/// Runs `body` against a fresh in-memory SQLite Fluent with every production migration applied,
/// and always shuts Fluent down afterwards. Fluent asserts at deinit when `shutdown()` was
/// skipped, which would crash the test process and hide the real failure.
func withTestFluent<T>(_ body: (Fluent) async throws -> T) async throws -> T {
    try await withFluent(migrations: legacyMigrations + taggerV2Migrations, body)
}

/// Same as `withTestFluent` but with only the pre-rewrite migrations applied, so a test can
/// seed legacy rows and then apply the phase 1 migrations with `applyTaggerV2`.
func withLegacyFluent<T>(_ body: (Fluent) async throws -> T) async throws -> T {
    try await withFluent(migrations: legacyMigrations, body)
}

func applyTaggerV2(_ fluent: Fluent) async throws {
    for migration in taggerV2Migrations {
        await fluent.migrations.add(migration)
    }
    try await fluent.migrate()
}

private func withFluent<T>(migrations: [any AsyncMigration], _ body: (Fluent) async throws -> T) async throws -> T {
    let fluent = Fluent(logger: Logger(label: "test"))
    fluent.databases.use(.sqlite(.memory), as: .sqlite)
    for migration in migrations {
        await fluent.migrations.add(migration)
    }
    do {
        try await fluent.migrate()
        let result = try await body(fluent)
        try await fluent.shutdown()
        return result
    } catch {
        try? await fluent.shutdown()
        throw error
    }
}

/// Builds an in-memory Fluent with every migration applied. The caller must call `shutdown()`.
/// Prefer `withTestFluent`.
func makeTestFluent() async throws -> Fluent {
    let logger = Logger(label: "test")
    let fluent = Fluent(logger: logger)
    fluent.databases.use(.sqlite(.memory), as: .sqlite)
    try await runMigrations(fluent: fluent, logger: logger)
    return fluent
}

/// Loads a fixture file from `Tests/NocturneServerTests/Fixtures`.
func fixtureData(_ relativePath: String) throws -> Data {
    guard let base = Bundle.module.resourceURL else { throw FixtureError.missing(relativePath) }
    let url = base.appendingPathComponent("Fixtures").appendingPathComponent(relativePath)
    guard FileManager.default.fileExists(atPath: url.path) else { throw FixtureError.missing(relativePath) }
    return try Data(contentsOf: url)
}

enum FixtureError: Error, CustomStringConvertible {
    case missing(String)
    var description: String {
        switch self {
        case .missing(let path): return "Fixture not found: \(path)"
        }
    }
}
