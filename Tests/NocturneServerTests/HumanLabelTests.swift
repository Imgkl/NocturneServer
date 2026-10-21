import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import Testing

@testable import NocturneServer

@Suite struct HumanLabelTests {
    private let config = NocturneConfiguration()

    /// Jev's two passes disagree, so the row waits for a human while cat-and-mouse is applied and
    /// heist-energy (0.6, under its floor) rides along as a suggestion.
    private func queue(_ fluent: Fluent) async throws -> (ReviewQueue, TaggerPipeline, ScriptedReader, ScriptedClassifier) {
        let reader = ScriptedReader(answer: answer([candidate("cat-and-mouse", 0.9), candidate("heist-energy", 0.5)]))
        let classifier = ScriptedClassifier(answer: classifierAnswer(["cat-and-mouse": 0.9, "heist-energy": 0.6], primary: "cat-and-mouse", secondPick: "heist-energy"))
        let (pipeline, movies, _) = try await makePipeline(fluent, config: config, enricher: ScriptedEnricher(), reader: reader, classifier: classifier)
        return (ReviewQueue(fluent: fluent, config: config, movies: movies, pipeline: pipeline, logger: Logger(label: "test")), pipeline, reader, classifier)
    }

    @Test func approvePromotesAutoTagsToUser() async throws {
        try await withTestFluent { fluent in
            try await Movie(jellyfinId: "jf-1").save(on: fluent.db())
            let (queue, pipeline, _, _) = try await queue(fluent)
            let sugg = try await pipeline.tag(jellyfinId: "jf-1", trigger: .manual)
            #expect(try await tagSlugs(fluent, "jf-1") == ["cat-and-mouse:auto"])

            let approved = try await queue.approve(try sugg.requireID())
            #expect(approved.status == "approved")
            #expect(approved.resolvedBy == "user")
            #expect(try await tagSlugs(fluent, "jf-1") == ["cat-and-mouse:user"])
            await #expect(throws: TaggerError.self) { _ = try await queue.approve(try sugg.requireID()) }
        }
    }

    @Test func approveWithOverrideReplacesTagsAsUser() async throws {
        try await withTestFluent { fluent in
            try await Movie(jellyfinId: "jf-1").save(on: fluent.db())
            let (queue, pipeline, _, _) = try await queue(fluent)
            let sugg = try await pipeline.tag(jellyfinId: "jf-1", trigger: .manual)
            let approved = try await queue.approve(try sugg.requireID(), overrideTags: ["heist-energy", "not-a-mood"])
            #expect(approved.suggestedTags == ["heist-energy"])
            #expect(approved.resolvedBy == "user")
            #expect(try await tagSlugs(fluent, "jf-1") == ["heist-energy:user"])
        }
    }

    @Test func rejectRemovesOnlyAutoTags() async throws {
        try await withTestFluent { fluent in
            try await Movie(jellyfinId: "jf-1").save(on: fluent.db())
            let (queue, pipeline, _, _) = try await queue(fluent)
            _ = try await queue.movies.updateMovieTags(jellyfinId: "jf-1", tagSlugs: ["cult-chaos"], replaceAll: false, labelSource: .user)
            let sugg = try await pipeline.tag(jellyfinId: "jf-1", trigger: .manual)
            #expect(try await tagSlugs(fluent, "jf-1").map(\.slug) == ["cat-and-mouse", "cult-chaos"])

            let rejected = try await queue.reject(try sugg.requireID())
            #expect(rejected.status == "rejected")
            #expect(rejected.resolvedBy == "user")
            #expect(try await tagSlugs(fluent, "jf-1") == ["cult-chaos:user"])
        }
    }

    @Test func adminEditResolvesPendingRowsAsUser() async throws {
        try await withTestFluent { fluent in
            try await Movie(jellyfinId: "jf-1").save(on: fluent.db())
            let (queue, pipeline, _, _) = try await queue(fluent)
            let sugg = try await pipeline.tag(jellyfinId: "jf-1", trigger: .manual)
            #expect(sugg.status == "pending")
            let entry = try await queue.movies.updateMovieTags(jellyfinId: "jf-1", tagSlugs: ["quiet-epics"], replaceAll: true, labelSource: .user)
            #expect(entry.tags == ["quiet-epics"])
            #expect(try await tagSlugs(fluent, "jf-1") == ["quiet-epics:user"])
            let row = try #require(try await TagSuggestion.find(try sugg.requireID(), on: fluent.db()))
            #expect(row.status == "approved")
            #expect(row.resolvedBy == "user")
        }
    }

    @Test func regenerateClearsAutoTagsAndTagsAgain() async throws {
        try await withTestFluent { fluent in
            try await Movie(jellyfinId: "jf-1").save(on: fluent.db())
            let (queue, pipeline, reader, classifier) = try await queue(fluent)
            let first = try await pipeline.tag(jellyfinId: "jf-1", trigger: .manual)
            reader.answer = answer([candidate("heist-energy", 0.95)])
            classifier.answer = classifierAnswer(["heist-energy": 0.9], primary: "heist-energy")
            let second = try await queue.regenerate(jellyfinId: "jf-1")
            #expect(second.id != first.id)
            #expect(try await tagSlugs(fluent, "jf-1") == ["heist-energy:auto"])
            #expect(try await TagSuggestion.find(try first.requireID(), on: fluent.db()) == nil)
        }
    }
}
