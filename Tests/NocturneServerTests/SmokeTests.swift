import FluentKit
import Testing

@testable import NocturneServer

@Suite struct SmokeTests {
    @Test func migrationsRunOnEmptyDatabase() async throws {
        let fluent = try await makeTestFluent()
        let movies = try await Movie.query(on: fluent.db()).count()
        #expect(movies == 0)
        // SeedMoodTags runs as part of the migration chain, so the tag table is populated.
        let tags = try await Tag.query(on: fluent.db()).count()
        #expect(tags > 0)
        try await fluent.shutdown()
    }
}
