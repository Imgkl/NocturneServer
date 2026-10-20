import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import Testing

@testable import NocturneServer

@Suite struct SuggestionFlowTests {
    private let config = NocturneConfiguration()

    @Test func mixedAnswerAppliesStrongTagsAndQueuesTheRest() async throws {
        try await withTestFluent { fluent in
            try await Movie(jellyfinId: "jf-heat").save(on: fluent.db())
            let enricher = ScriptedEnricher()
            let reader = ScriptedReader(answer: answer([candidate("cat-and-mouse", 0.9), candidate("crime-grit-style", 0.85), candidate("bittersweet-aftermath", 0.7)]), fluent: fluent)
            reader.costPerCall = 0.0012
            let (pipeline, _, _) = try await makePipeline(fluent, config: config, enricher: enricher, reader: reader)

            let sugg = try await pipeline.tag(jellyfinId: "jf-heat", trigger: .manual)
            #expect(sugg.status == "pending")
            #expect(sugg.suggestedTags == ["cat-and-mouse", "crime-grit-style"])
            #expect(sugg.resolvedBy == nil)
            #expect(sugg.reasoning == "A quiet ache.")
            let items = try JSONDecoder().decode([SuggestionItem].self, from: Data(try #require(sugg.itemsJson).utf8))
            #expect(items.map(\.slug) == ["cat-and-mouse", "crime-grit-style", "bittersweet-aftermath"])
            #expect(items.map(\.applied) == [true, true, false])

            let tags = try await tagSlugs(fluent, "jf-heat")
            #expect(tags.map(\.slug) == ["cat-and-mouse", "crime-grit-style"])
            #expect(tags.allSatisfy { $0.source == "auto" })

            let decision = try #require(try await Decision.find(try #require(sugg.decisionId), on: fluent.db()))
            #expect(decision.outcome == "review")
            #expect(decision.readerJson?.contains("cat-and-mouse") == true)
            #expect(abs(decision.costUsd - 0.0012) < 1e-9)
            let models = try JSONDecoder().decode([String: String].self, from: Data(decision.modelsJson.utf8))
            #expect(models["enrichment_source"] == "wikipedia")
            #expect(models["reader"] == "claude-haiku-5-5")
            let movie = try #require(try await Movie.query(on: fluent.db()).filter(\.$jellyfinId == "jf-heat").first())
            #expect(movie.currentDecisionId == decision.id)
            #expect(reader.lastTextBlock == enricher.textBlock)
            #expect(enricher.enrichCalls == ["jf-heat"])
        }
    }

    @Test func enrichmentSourceRidesAlongForTheReviewUI() async throws {
        try await withTestFluent { fluent in
            try await Movie(jellyfinId: "jf-model").save(on: fluent.db())
            try await Movie(jellyfinId: "jf-wiki").save(on: fluent.db())
            let enricher = ScriptedEnricher()
            enricher.source = .model
            let reader = ScriptedReader(answer: answer([candidate("cat-and-mouse", 0.95)]))
            let (pipeline, movies, _) = try await makePipeline(fluent, config: config, enricher: enricher, reader: reader)
            let fromModel = try await pipeline.tag(jellyfinId: "jf-model", trigger: .manual)
            enricher.source = .wikipedia
            let fromWiki = try await pipeline.tag(jellyfinId: "jf-wiki", trigger: .manual)
            let orphan = TagSuggestion(jellyfinId: "jf-legacy", suggestedTags: ["cat-and-mouse"], confidence: 0.5, reasoning: nil, status: "pending")
            try await orphan.save(on: fluent.db())

            let queue = ReviewQueue(fluent: fluent, config: config, movies: movies, pipeline: pipeline)
            let sources = try await queue.enrichmentSources(for: [fromModel, fromWiki, orphan])
            #expect(sources[try #require(fromModel.decisionId)] == "model")
            #expect(sources[try #require(fromWiki.decisionId)] == "wikipedia")
            #expect(sources.count == 2)
            #expect(fromModel.status == "pending")  // unverified text never auto-applies
            let encoded = try TagSuggestionResponse(fromModel, source: "model").toJSONString()
            #expect(encoded.contains("\"source\" : \"model\""))
            #expect(try await queue.enrichmentSources(for: [orphan]).isEmpty)
        }
    }

    @Test func allStrongIsAutoApproved() async throws {
        try await withTestFluent { fluent in
            try await Movie(jellyfinId: "jf-1").save(on: fluent.db())
            let reader = ScriptedReader(answer: answer([candidate("cat-and-mouse", 0.95)]))
            let (pipeline, _, _) = try await makePipeline(fluent, config: config, enricher: ScriptedEnricher(), reader: reader)
            let sugg = try await pipeline.tag(jellyfinId: "jf-1", trigger: .realtime)
            #expect(sugg.status == "approved")
            #expect(sugg.resolvedBy == "auto")
            #expect(sugg.resolvedAt != nil)
            let decision = try #require(try await Decision.find(try #require(sugg.decisionId), on: fluent.db()))
            #expect(decision.outcome == "applied")
        }
    }

    @Test func readerFailureWritesErrorDecisionAndEmptyPendingRow() async throws {
        try await withTestFluent { fluent in
            try await Movie(jellyfinId: "jf-1").save(on: fluent.db())
            let reader = ScriptedReader(answer: answer([]))
            reader.error = ReaderError.malformed("nope")
            let (pipeline, _, _) = try await makePipeline(fluent, config: config, enricher: ScriptedEnricher(), reader: reader)
            let sugg = try await pipeline.tag(jellyfinId: "jf-1", trigger: .manual)
            #expect(sugg.status == "pending")
            #expect(sugg.suggestedTags.isEmpty)
            #expect(sugg.reasoning?.contains("auto-tagger failed") == true)
            let decision = try #require(try await Decision.find(try #require(sugg.decisionId), on: fluent.db()))
            #expect(decision.outcome == "error")
            #expect(try await tagSlugs(fluent, "jf-1").isEmpty)
        }
    }

    @Test func authFailurePropagatesAfterRecording() async throws {
        try await withTestFluent { fluent in
            try await Movie(jellyfinId: "jf-1").save(on: fluent.db())
            let reader = ScriptedReader(answer: answer([]))
            reader.error = OutboundError.authFailure(provider: "anthropic", status: 401)
            let (pipeline, _, _) = try await makePipeline(fluent, config: config, enricher: ScriptedEnricher(), reader: reader)
            do {
                _ = try await pipeline.tag(jellyfinId: "jf-1", trigger: .manual)
                Issue.record("expected a throw")
            } catch let error as OutboundError {
                #expect(error.isAuthFailure)
            }
            #expect(try await Decision.query(on: fluent.db()).filter(\.$outcome == "error").count() == 1)
            #expect(try await TagSuggestion.query(on: fluent.db()).count() == 0)
        }
    }

    @Test func budgetPauseSkipsWithoutCallingTheReader() async throws {
        try await withTestFluent { fluent in
            try await Movie(jellyfinId: "jf-1").save(on: fluent.db())
            let reader = ScriptedReader(answer: answer([candidate("cat-and-mouse", 0.95)]))
            let (pipeline, _, _) = try await makePipeline(fluent, config: config, enricher: ScriptedEnricher(), reader: reader, budgetCap: "0.5")
            try await ApiCall(runId: nil, decisionId: nil, provider: "anthropic", endpoint: "/", model: nil, attempt: 1, httpStatus: 200, durationMs: 1, unitsJson: "{}", costUsd: 1.0).save(on: fluent.db())

            let sugg = try await pipeline.tag(jellyfinId: "jf-1", trigger: .realtime)
            #expect(sugg.status == "pending")
            #expect(sugg.reasoning?.contains("budget cap reached") == true)
            #expect(reader.calls == 0)
            let decision = try #require(try await Decision.find(try #require(sugg.decisionId), on: fluent.db()))
            #expect(decision.outcome == "skipped")

            // Manual work proceeds past the cap.
            _ = try await pipeline.tag(jellyfinId: "jf-1", trigger: .manual, replaceExistingPending: true)
            #expect(reader.calls == 1)
        }
    }

    @Test func noStorySourceTagsWithTodaySemantics() async throws {
        try await withTestFluent { fluent in
            try await Movie(jellyfinId: "jf-1").save(on: fluent.db())
            let enricher = ScriptedEnricher()
            enricher.source = .none
            enricher.textBlock = nil
            enricher.identityJson = EnrichmentService.json(EnrichmentService.Identity(title: "Obscure Film", originalTitle: nil, year: 2001, director: nil, runtimeMinutes: nil, genres: ["Drama"], cast: [], overview: "A pitch.", imdbId: nil, tmdbId: nil))
            let reader = ScriptedReader(answer: answer([candidate("cat-and-mouse", 0.95)]))
            let (pipeline, _, _) = try await makePipeline(fluent, config: config, enricher: enricher, reader: reader)

            let sugg = try await pipeline.tag(jellyfinId: "jf-1", trigger: .manual)
            #expect(sugg.status == "approved")
            #expect(reader.lastTextBlock?.contains("Title: Obscure Film (2001)") == true)
            #expect(reader.lastTextBlock?.contains("A pitch.") == true)
            #expect(reader.lastTextBlock?.contains("# Plot (Wikipedia, full, contains spoilers)\n(none)") == true)
            let decision = try #require(try await Decision.find(try #require(sugg.decisionId), on: fluent.db()))
            let models = try JSONDecoder().decode([String: String].self, from: Data(decision.modelsJson.utf8))
            #expect(models["enrichment_source"] == "none")
        }
    }

    @Test func modelWrittenSourceForcesReview() async throws {
        try await withTestFluent { fluent in
            try await Movie(jellyfinId: "jf-1").save(on: fluent.db())
            let enricher = ScriptedEnricher()
            enricher.source = .model
            let reader = ScriptedReader(answer: answer([candidate("cat-and-mouse", 0.95)]))
            let (pipeline, _, _) = try await makePipeline(fluent, config: config, enricher: enricher, reader: reader)
            let sugg = try await pipeline.tag(jellyfinId: "jf-1", trigger: .manual)
            #expect(sugg.status == "pending")
            #expect(sugg.suggestedTags.isEmpty)
            #expect(try await tagSlugs(fluent, "jf-1").isEmpty)
        }
    }

    @Test func existingPendingRowShortCircuitsUnlessReplaced() async throws {
        try await withTestFluent { fluent in
            try await Movie(jellyfinId: "jf-1").save(on: fluent.db())
            let reader = ScriptedReader(answer: answer([candidate("cat-and-mouse", 0.5)]))
            let (pipeline, _, _) = try await makePipeline(fluent, config: config, enricher: ScriptedEnricher(), reader: reader)
            let first = try await pipeline.tag(jellyfinId: "jf-1", trigger: .manual)
            let again = try await pipeline.tag(jellyfinId: "jf-1", trigger: .manual)
            #expect(again.id == first.id)
            #expect(reader.calls == 1)
            let replaced = try await pipeline.tag(jellyfinId: "jf-1", trigger: .manual, replaceExistingPending: true)
            #expect(replaced.id != first.id)
            #expect(reader.calls == 2)
            #expect(try await TagSuggestion.find(try first.requireID(), on: fluent.db())?.status == "superseded")
        }
    }

    @Test func missingKeyThrows() async throws {
        try await withTestFluent { fluent in
            try await Movie(jellyfinId: "jf-1").save(on: fluent.db())
            let (pipeline, _, _) = try await makePipeline(fluent, config: config, enricher: ScriptedEnricher(), reader: ScriptedReader(answer: answer([])), apiKey: nil)
            await #expect(throws: TaggerError.self) {
                _ = try await pipeline.tag(jellyfinId: "jf-1", trigger: .manual)
            }
        }
    }
}
