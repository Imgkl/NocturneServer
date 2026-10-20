import Foundation
import FluentKit
import FluentSQLiteDriver
import HummingbirdFluent
import Logging

@testable import NocturneServer

/// Builds an in-memory SQLite Fluent instance with every production migration applied.
/// Each call gets its own database, so tests never share state.
func makeTestFluent() async throws -> Fluent {
    let logger = Logger(label: "test")
    let fluent = Fluent(logger: logger)
    fluent.databases.use(.sqlite(.memory), as: .sqlite)
    try await runMigrations(fluent: fluent, logger: logger)
    return fluent
}

/// Loads a fixture file from `Tests/NocturneServerTests/Fixtures`.
func fixtureData(_ relativePath: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: "Fixtures/\(relativePath)", withExtension: nil)
        ?? Bundle.module.resourceURL?.appendingPathComponent("Fixtures/\(relativePath)")
    else {
        throw FixtureError.missing(relativePath)
    }
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
