import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import Testing

@testable import NocturneServer

@Suite struct TagCalibrationTests {
    private let config = NocturneConfiguration()

    private func movie(_ fluent: Fluent, _ jellyfinId: String, tags: [(String, LabelSource)]) async throws {
        let db = fluent.db()
        let movie = Movie(jellyfinId: jellyfinId)
        try await movie.save(on: db)
        for (slug, source) in tags {
            let tag = try await Tag.query(on: db).filter(\.$slug == slug).first() ?? {
                let t = Tag(slug: slug, title: slug, description: slug)
                return t
            }()
            if tag.id == nil { try await tag.save(on: db) }
            try await MovieTag(movieId: try movie.requireID(), tagId: try tag.requireID(), labelSource: source).save(on: db)
        }
    }

    private func suggestion(_ fluent: Fluent, _ jellyfinId: String, tags: [String], status: String, resolvedBy: String?, ageSeconds: TimeInterval) async throws {
        let s = TagSuggestion(jellyfinId: jellyfinId, suggestedTags: tags, confidence: 0.9, reasoning: nil, status: status)
        s.resolvedBy = resolvedBy
        s.resolvedAt = Date().addingTimeInterval(-ageSeconds)
        try await s.save(on: fluent.db())
    }

    @Test func onlyHumanLabelsCount() async throws {
        try await withTestFluent { fluent in
            // A: auto-approved (must be ignored). B: human-approved, kept. C: human-rejected.
            // D: manual tag. E: human-approved but the admin removed one tag (edit).
            try await movie(fluent, "A", tags: [("ha-ha-ha", .auto)])
            try await suggestion(fluent, "A", tags: ["ha-ha-ha"], status: "approved", resolvedBy: "auto", ageSeconds: 10)
            try await movie(fluent, "B", tags: [("ha-ha-ha", .user)])
            try await suggestion(fluent, "B", tags: ["ha-ha-ha"], status: "approved", resolvedBy: "user", ageSeconds: 20)
            try await movie(fluent, "C", tags: [])
            try await suggestion(fluent, "C", tags: ["ha-ha-ha"], status: "rejected", resolvedBy: "user", ageSeconds: 30)
            try await movie(fluent, "D", tags: [("cult-chaos", .user)])
            try await movie(fluent, "E", tags: [("heist-energy", .user)])
            try await suggestion(fluent, "E", tags: ["heist-energy", "cat-and-mouse"], status: "approved", resolvedBy: "user", ageSeconds: 40)

            let titles = ["A": "Auto Film", "B": "Big Lebowski", "C": "Manchester", "D": "The Room", "E": "Heat"]
            let cal = try await buildCalibration(fluent: fluent, titles: titles, availableTags: config.moodBuckets)

            #expect(cal["ha-ha-ha"]?.positives == ["Big Lebowski"])
            #expect(cal["ha-ha-ha"]?.negatives == ["Manchester"])
            #expect(cal["cult-chaos"]?.positives == ["The Room"])
            #expect(cal["heist-energy"]?.positives == ["Heat"])
            #expect(cal["cat-and-mouse"]?.negatives == ["Heat"])
            let everything = cal.values.flatMap { $0.positives + $0.negatives }
            #expect(!everything.contains("Auto Film"))
        }
    }

    @Test func capsAndUnknownSlugsAndMissingTitles() async throws {
        try await withTestFluent { fluent in
            for i in 1...8 {
                try await movie(fluent, "F\(i)", tags: [("ha-ha-ha", .user)])
                try await suggestion(fluent, "F\(i)", tags: ["ha-ha-ha"], status: "approved", resolvedBy: "user", ageSeconds: Double(i))
            }
            for i in 1...5 {
                try await movie(fluent, "R\(i)", tags: [])
                try await suggestion(fluent, "R\(i)", tags: ["ha-ha-ha", "not-a-mood"], status: "rejected", resolvedBy: "user", ageSeconds: Double(i))
            }
            let cal = try await buildCalibration(fluent: fluent, titles: ["F1": "First"], availableTags: config.moodBuckets)
            #expect(cal["ha-ha-ha"]?.positives.count == 5)
            #expect(cal["ha-ha-ha"]?.positives.first == "First")   // most recent first
            #expect(cal["ha-ha-ha"]?.negatives.count == 3)
            #expect(cal["ha-ha-ha"]?.negatives.first == "R1")       // falls back to the id
            #expect(cal["not-a-mood"] == nil)
        }
    }

    @Test func emptyDatabaseGivesEmptyCalibration() async throws {
        try await withTestFluent { fluent in
            let cal = try await buildCalibration(fluent: fluent, titles: [:], availableTags: config.moodBuckets)
            #expect(cal.isEmpty)
        }
    }
}
