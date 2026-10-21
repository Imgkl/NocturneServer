import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import Testing

@testable import NocturneServer

@Suite struct SuggestionFlowTests {
    private let config = NocturneConfiguration()

    @Test func mixedAnswerAppliesStrongTagsAndKeepsTheRestAsSuggestions() async throws {
        try await withTestFluent { fluent in
            try await Movie(jellyfinId: "jf-heat").save(on: fluent.db())
            let enricher = ScriptedEnricher()
            let reader = ScriptedReader(answer: answer([candidate("cat-and-mouse", 0.9), candidate("crime-grit-style", 0.85), candidate("bittersweet-aftermath", 0.7)]), fluent: fluent)
            reader.costPerCall = 0.0012
            let (pipeline, _, _) = try await makePipeline(fluent, config: config, enricher: enricher, reader: reader)

            let sugg = try await pipeline.tag(jellyfinId: "jf-heat", trigger: .manual)
            #expect(sugg.status == "approved")  // tags applied and a suggestion below the floor: no human needed
            #expect(sugg.suggestedTags == ["cat-and-mouse", "crime-grit-style"])
            #expect(sugg.resolvedBy == "auto")
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

    @Test func capCountsTheAdminsOwnTags() async throws {
        try await withTestFluent { fluent in
            try await Movie(jellyfinId: "jf-cap").save(on: fluent.db())
            let reader = ScriptedReader(answer: answer([
                candidate("cat-and-mouse", 0.95), candidate("heist-energy", 0.95), candidate("time-twists", 0.95), candidate("obsidian-noir", 0.95),
            ]))
            let (pipeline, movies, _) = try await makePipeline(fluent, config: config, enricher: ScriptedEnricher(), reader: reader)
            _ = try await movies.updateMovieTags(jellyfinId: "jf-cap", tagSlugs: ["ha-ha-ha", "coming-of-age", "quiet-epics"], replaceAll: true, labelSource: .user)

            let sugg = try await pipeline.tag(jellyfinId: "jf-cap", trigger: .manual)
            #expect(sugg.suggestedTags == ["cat-and-mouse", "heist-energy"])
            let items = try JSONDecoder().decode([SuggestionItem].self, from: Data(try #require(sugg.itemsJson).utf8))
            #expect(items.filter { !$0.applied }.map(\.reason) == ["cap of 2 reached", "cap of 2 reached"])
            let tags = try await tagSlugs(fluent, "jf-cap")
            #expect(tags.count == 5)
            #expect(tags.filter { $0.source == "user" }.count == 3)
        }
    }

    @Test func pendingRowsFollowTheirFilmOutOfTheLibrary() async throws {
        try await withTestFluent { fluent in
            try await Movie(jellyfinId: "jf-stay").save(on: fluent.db())
            try await Movie(jellyfinId: "jf-go").save(on: fluent.db())
            for id in ["jf-stay", "jf-go", "jf-ghost"] {
                try await TagSuggestion(jellyfinId: id, suggestedTags: ["cult-chaos"], confidence: 0.5, reasoning: nil, status: "pending").save(on: fluent.db())
            }
            let reader = ScriptedReader(answer: answer([]))
            let (pipeline, movies, _) = try await makePipeline(fluent, config: config, enricher: ScriptedEnricher(), reader: reader)
            let queue = ReviewQueue(fluent: fluent, config: config, movies: movies, pipeline: pipeline)

            // A row for a film that was never in the library is hidden, not shown as a bare id.
            #expect(try await queue.listPending().map(\.jellyfinId).sorted() == ["jf-go", "jf-stay"])

            #expect(try await movies.deleteMovieByJellyfinId("jf-go"))
            #expect(try await queue.listPending().map(\.jellyfinId) == ["jf-stay"])
            let gone = try #require(try await TagSuggestion.query(on: fluent.db()).filter(\.$jellyfinId == "jf-go").first())
            #expect(gone.status == "superseded")
            #expect(gone.resolvedAt != nil)

            // Clearing the library supersedes every open row, the ghost included.
            try await movies.clearAllMovies()
            #expect(try await queue.listPending().isEmpty)
            #expect(try await TagSuggestion.query(on: fluent.db()).filter(\.$status == "pending").count() == 0)
            #expect(try await TagSuggestion.query(on: fluent.db()).filter(\.$status == "superseded").count() == 3)
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

    @Test func classifierOfRecordDecidesUnderP1AndIsStoredOnTheDecision() async throws {
        try await withTestFluent { fluent in
            try await Movie(jellyfinId: "jf-1").save(on: fluent.db())
            let reader = ScriptedReader(answer: answer([candidate("cat-and-mouse", 0.95, evidence: "duel"), candidate("ha-ha-ha", 0.9, evidence: "gags")]))
            let classifier = ScriptedClassifier(answer: classifierAnswer(["cat-and-mouse": 0.92, "ha-ha-ha": 0.4, "heist-energy": 0.9], primary: "cat-and-mouse"))
            let (pipeline, _, _) = try await makePipeline(fluent, config: config, enricher: ScriptedEnricher(), reader: reader, classifier: classifier)
            let sugg = try await pipeline.tag(jellyfinId: "jf-1", trigger: .manual)
            #expect(classifier.calls == 1)
            #expect(classifier.lastGuide??.contains("Rule 0") == true)
            #expect(sugg.suggestedTags == ["cat-and-mouse"])
            #expect(sugg.status == "approved")  // ha-ha-ha and heist-energy ride along as suggestions; the passes agree
            let items = try JSONDecoder().decode([SuggestionItem].self, from: Data(try #require(sugg.itemsJson).utf8))
            #expect(items.map(\.slug) == ["cat-and-mouse", "heist-energy", "ha-ha-ha"])
            #expect(items[1].reason == "classifier 0.9, reader silent")
            #expect(try await tagSlugs(fluent, "jf-1") == ["cat-and-mouse:auto"])
            let decision = try #require(try await Decision.query(on: fluent.db()).filter(\.$jellyfinId == "jf-1").first())
            #expect(decision.policyVersion == "p1")
            #expect(decision.classifierProvider == "typesafe")
            #expect(decision.classifierJson?.contains("mood_cat_and_mouse") == true)  // the raw answer, replayable
            let models = try JSONDecoder().decode([String: String].self, from: Data(decision.modelsJson.utf8))
            #expect(models["classifier"] == "jev-1.13.0")
        }
    }

    @Test func aFailedClassifierDegradesToTheReaderAndLeavesTheFilmUnsure() async throws {
        try await withTestFluent { fluent in
            try await Movie(jellyfinId: "jf-2").save(on: fluent.db())
            let reader = ScriptedReader(answer: answer([candidate("cat-and-mouse", 0.95)]))
            let classifier = ScriptedClassifier(answer: classifierAnswer(["cat-and-mouse": 0.9]))
            classifier.error = OutboundError.exhausted(provider: "typesafe", lastStatus: 503)
            let (pipeline, _, _) = try await makePipeline(fluent, config: config, enricher: ScriptedEnricher(), reader: reader, classifier: classifier)
            let sugg = try await pipeline.tag(jellyfinId: "jf-2", trigger: .manual)
            #expect(sugg.suggestedTags == ["cat-and-mouse"])  // legacy floors still apply the tag
            #expect(sugg.status == "pending")  // but it waits for a human
            #expect(try await tagSlugs(fluent, "jf-2") == ["cat-and-mouse:auto"])
            let decision = try #require(try await Decision.query(on: fluent.db()).filter(\.$jellyfinId == "jf-2").first())
            #expect(decision.policyVersion == "p-legacy")
            #expect(decision.unsure)
            #expect(decision.reasonsJson.contains("classifier unavailable"))

            classifier.error = OutboundError.authFailure(provider: "typesafe", status: 401)
            try await Movie(jellyfinId: "jf-3").save(on: fluent.db())
            await #expect(throws: OutboundError.self) { try await pipeline.tag(jellyfinId: "jf-3", trigger: .manual) }
        }
    }

    @Test func regradeReusesTheReaderAnswerAndReportsRemovals() async throws {
        try await withTestFluent { fluent in
            try await Movie(jellyfinId: "jf-4").save(on: fluent.db())
            let reader = ScriptedReader(answer: answer([candidate("cat-and-mouse", 0.95), candidate("ha-ha-ha", 0.9)]))
            let classifier = ScriptedClassifier(answer: classifierAnswer(["cat-and-mouse": 0.92, "ha-ha-ha": 0.9], primary: "cat-and-mouse"))
            let (pipeline, movies, _) = try await makePipeline(fluent, config: config, enricher: ScriptedEnricher(), reader: reader, classifier: classifier)
            let first = try await pipeline.tag(jellyfinId: "jf-4", trigger: .manual)
            #expect(first.status == "approved")
            #expect(try await tagSlugs(fluent, "jf-4") == ["cat-and-mouse:auto", "ha-ha-ha:auto"])

            // The classifier changes its mind about ha-ha-ha; the reader is not called again.
            classifier.answer = classifierAnswer(["cat-and-mouse": 0.93, "ha-ha-ha": 0.3], primary: "cat-and-mouse")
            let regraded = try await pipeline.regrade(jellyfinId: "jf-4", trigger: .manual)
            #expect(reader.calls == 1)
            #expect(classifier.calls == 2)
            #expect(regraded.status == "pending")
            #expect(try await tagSlugs(fluent, "jf-4") == ["cat-and-mouse:auto", "ha-ha-ha:auto"])  // nothing removed silently
            let items = try JSONDecoder().decode([SuggestionItem].self, from: Data(try #require(regraded.itemsJson).utf8))
            #expect(items.contains { $0.slug == "ha-ha-ha" && $0.kind == .remove })
            #expect(first.status == "approved")
            let decisions = try await Decision.query(on: fluent.db()).filter(\.$jellyfinId == "jf-4").all()
            #expect(decisions.count == 2)
            #expect(decisions.allSatisfy { $0.readerJson?.contains("cat-and-mouse") == true })
            let regradeDecision = try #require(decisions.first { ($0.reasonsJson).contains("removal suggested") })
            #expect(regradeDecision.modelsJson.contains("\"regrade\":\"true\""))
            #expect(try await TagSuggestion.query(on: fluent.db()).filter(\.$jellyfinId == "jf-4").filter(\.$status == "pending").count() == 1)
            #expect(regraded.kind == TaggerPipeline.regradeKind)

            // Approving the regrade takes the new decision: ha-ha-ha comes off, cat-and-mouse becomes the owner's.
            let queue = ReviewQueue(fluent: fluent, config: config, movies: movies, pipeline: pipeline)
            _ = try await queue.approve(try regraded.requireID())
            #expect(try await tagSlugs(fluent, "jf-4") == ["cat-and-mouse:user"])
        }
    }

    /// A regrade that adds a mood the owner has not seen yet: reject puts the film back as it was,
    /// approve with an edited set keeps the owner's own earlier tags.
    @Test func regradeRejectUndoesWhatItAddedAndOverrideKeepsTheOwnersTags() async throws {
        try await withTestFluent { fluent in
            for id in ["jf-5", "jf-6"] { try await Movie(jellyfinId: id).save(on: fluent.db()) }
            let reader = ScriptedReader(answer: answer([candidate("cat-and-mouse", 0.95), candidate("ha-ha-ha", 0.9)]))
            let classifier = ScriptedClassifier(answer: classifierAnswer(["cat-and-mouse": 0.92, "ha-ha-ha": 0.3], primary: "cat-and-mouse"))
            let (pipeline, movies, _) = try await makePipeline(fluent, config: config, enricher: ScriptedEnricher(), reader: reader, classifier: classifier)
            let queue = ReviewQueue(fluent: fluent, config: config, movies: movies, pipeline: pipeline)
            for id in ["jf-5", "jf-6"] {
                let first = try await pipeline.tag(jellyfinId: id, trigger: .manual)
                #expect(first.status == "approved" && first.resolvedBy == "auto")  // ha-ha-ha below the floor rides along as a suggestion
                try await movies.promoteAutoTagsToUser(jellyfinId: id)  // the owner confirms the film on the spot check
                #expect(try await tagSlugs(fluent, id) == ["cat-and-mouse:user"])
            }

            // The classifier now backs ha-ha-ha but its two passes disagree: applied, yet the row needs a human.
            classifier.answer = classifierAnswer(["cat-and-mouse": 0.93, "ha-ha-ha": 0.9], primary: "cat-and-mouse", secondPick: "ha-ha-ha")
            let rejectedRow = try await pipeline.regrade(jellyfinId: "jf-5", trigger: .manual)
            #expect(rejectedRow.status == "pending" && rejectedRow.kind == TaggerPipeline.regradeKind)
            #expect(try await tagSlugs(fluent, "jf-5") == ["cat-and-mouse:user", "ha-ha-ha:auto"])
            let items = try JSONDecoder().decode([SuggestionItem].self, from: Data(try #require(rejectedRow.itemsJson).utf8))
            #expect(items.first { $0.slug == "ha-ha-ha" }?.reason == TaggerPipeline.addedOnRegrade)
            #expect(items.first { $0.slug == "cat-and-mouse" }?.reason == nil)
            _ = try await queue.reject(try rejectedRow.requireID())
            #expect(try await tagSlugs(fluent, "jf-5") == ["cat-and-mouse:user"])

            let editedRow = try await pipeline.regrade(jellyfinId: "jf-6", trigger: .manual)
            _ = try await queue.approve(try editedRow.requireID(), overrideTags: ["ha-ha-ha", "quiet-epics"])
            #expect(try await tagSlugs(fluent, "jf-6") == ["cat-and-mouse:user", "ha-ha-ha:user", "quiet-epics:user"])
        }
    }

    /// A replay re-applies the policy from the stored answers: a lowered floor applies the mood the
    /// grader backed, with no call to the reader or the grader.
    @Test func replayReappliesTheStoredAnswersUnderNewFloors() async throws {
        try await withTestFluent { fluent in
            try await Movie(jellyfinId: "jf-7").save(on: fluent.db())
            let reader = ScriptedReader(answer: answer([candidate("cat-and-mouse", 0.95), candidate("ha-ha-ha", 0.9)]))
            let classifier = ScriptedClassifier(answer: classifierAnswer(["cat-and-mouse": 0.92, "ha-ha-ha": 0.65], primary: "cat-and-mouse"))
            let (pipeline, _, settings) = try await makePipeline(fluent, config: config, enricher: ScriptedEnricher(), reader: reader, classifier: classifier)
            let first = try await pipeline.tag(jellyfinId: "jf-7", trigger: .manual)
            #expect(first.status == "approved")
            #expect(try await tagSlugs(fluent, "jf-7") == ["cat-and-mouse:auto"])  // ha-ha-ha at 0.65 is under its 0.80 floor

            try await settings.set(PolicyConfig.floorsSetting, PolicyConfig.encode(["ha-ha-ha": 0.6]))
            let replayed = try await pipeline.regrade(jellyfinId: "jf-7", trigger: .manual, reuseClassifier: true)
            #expect(reader.calls == 1 && classifier.calls == 1)
            #expect(replayed.status == "approved" && replayed.kind == TaggerPipeline.regradeKind)
            #expect(try await tagSlugs(fluent, "jf-7") == ["cat-and-mouse:auto", "ha-ha-ha:auto"])
            let decision = try #require(try await Decision.find(try #require(replayed.decisionId), on: fluent.db()))
            #expect(decision.modelsJson.contains("\"replay\":\"true\""))
            #expect(decision.policyVersion == "p1")
        }
    }
}
