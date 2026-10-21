import FluentKit
import Foundation
import Logging
import Testing

@testable import NocturneServer

@Suite struct VerifyServiceTests {
    private let config = NocturneConfiguration()

    @Test func sampleIsSeededAndJudgedFilmsBecomeLabels() async throws {
        try await withTestFluent { fluent in
            for id in ["jf-a", "jf-b", "jf-c"] { try await Movie(jellyfinId: id).save(on: fluent.db()) }
            let reader = ScriptedReader(answer: answer([candidate("cat-and-mouse", 0.95, evidence: "duel"), candidate("ha-ha-ha", 0.9, evidence: "gags")]))
            let classifier = ScriptedClassifier(answer: classifierAnswer(["cat-and-mouse": 0.92, "ha-ha-ha": 0.9], primary: "cat-and-mouse"))
            let (pipeline, movies, settings) = try await makePipeline(fluent, config: config, enricher: ScriptedEnricher(), reader: reader, classifier: classifier)
            for id in ["jf-a", "jf-b", "jf-c"] { _ = try await pipeline.tag(jellyfinId: id, trigger: .manual) }
            let verify = VerifyService(fluent: fluent, config: config, movies: movies, logger: Logger(label: "test"))

            // The same seed gives the same films; a reload before judging shows the same page.
            let s1 = try await verify.sample(count: 2, seed: "x")
            let s2 = try await verify.sample(count: 2, seed: "x")
            #expect(s1.films.map(\.jellyfinId) == s2.films.map(\.jellyfinId))
            #expect(s1.films.count == 2 && s1.remaining == 1)
            #expect(s1.films[0].moods.map(\.slug) == ["cat-and-mouse", "ha-ha-ha"])  // grader probability, highest first
            #expect(s1.films[0].moods[0].evidence == "duel" && s1.films[0].moods[0].probability == 0.92)
            #expect(s1.tally == VerifyService.Tally(films: 0, judged: 0, right: 0, wrong: 0))

            // The verdict: the wrong mood comes off, the kept one becomes the owner's, a user-resolved row records it.
            let target = s1.films[0].jellyfinId
            let saved = try await verify.save(jellyfinId: target, wrong: ["ha-ha-ha", "not-applied"])
            #expect(saved.kept == ["cat-and-mouse"] && saved.wrong == ["ha-ha-ha"])
            #expect(saved.tally == VerifyService.Tally(films: 1, judged: 2, right: 1, wrong: 1))
            #expect(try await tagSlugs(fluent, target) == ["cat-and-mouse:user"])
            let row = try #require(try await TagSuggestion.query(on: fluent.db()).filter(\.$kind == VerifyService.kind).first())
            #expect(row.status == "approved" && row.resolvedBy == "user" && row.suggestedTags == ["cat-and-mouse", "ha-ha-ha"])

            // Judged films leave the sample; the eval reads the kept mood as right and the wrong one as wrong.
            let s3 = try await verify.sample(count: 5, seed: "x")
            #expect(!s3.films.map(\.jellyfinId).contains(target) && s3.remaining == 0 && s3.films.count == 2)
            let eval = EvalService(fluent: fluent, config: config, settings: settings, runService: RunService(fluent: fluent))
            let films = try await eval.labelledFilms()
            #expect(films.count == 1 && films[0].positives == ["cat-and-mouse"] && films[0].negatives == ["ha-ha-ha"])
            await #expect(throws: VerifyError.self) { _ = try await verify.save(jellyfinId: target, wrong: []) }
        }
    }
}
