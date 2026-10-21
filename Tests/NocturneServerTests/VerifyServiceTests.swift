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
            let s1 = try await verify.sample(count: 2, seed: "x", scope: .all)
            let s2 = try await verify.sample(count: 2, seed: "x", scope: .all)
            #expect(s1.films.map(\.jellyfinId) == s2.films.map(\.jellyfinId))
            #expect(s1.films.count == 2 && s1.remaining == 1)
            #expect(s1.counts == ["watched.tagged": 0, "watched.untagged": 0, "all.tagged": 3, "all.untagged": 0])
            #expect(try await verify.sample(count: 5, seed: "x", scope: .watched).films.isEmpty)  // nothing watched yet
            #expect(s1.films[0].candidates.isEmpty)  // every mood AI named is on the film
            #expect(s1.films[0].moods.map(\.slug) == ["cat-and-mouse", "ha-ha-ha"])  // grader probability, highest first
            #expect(s1.films[0].moods[0].evidence == "duel" && s1.films[0].moods[0].probability == 0.92)
            #expect(s1.tally == VerifyService.Tally(films: 0, judged: 0, right: 0, wrong: 0))

            // The verdict: the wrong mood comes off, the kept one becomes the owner's, a user-resolved row records it.
            let target = s1.films[0].jellyfinId
            let saved = try await verify.save(jellyfinId: target, wrong: ["ha-ha-ha", "not-applied"])
            #expect(saved.kept == ["cat-and-mouse"] && saved.wrong == ["ha-ha-ha"] && saved.added.isEmpty)
            #expect(saved.tally == VerifyService.Tally(films: 1, judged: 2, right: 1, wrong: 1))
            #expect(try await tagSlugs(fluent, target) == ["cat-and-mouse:user"])
            let row = try #require(try await TagSuggestion.query(on: fluent.db()).filter(\.$kind == VerifyService.kind).first())
            #expect(row.status == "approved" && row.resolvedBy == "user" && row.suggestedTags == ["cat-and-mouse", "ha-ha-ha"])

            // Judged films leave the sample; the eval reads the kept mood as right and the wrong one as wrong.
            let s3 = try await verify.sample(count: 5, seed: "x", scope: .all)
            #expect(!s3.films.map(\.jellyfinId).contains(target) && s3.remaining == 0 && s3.films.count == 2)
            let eval = EvalService(fluent: fluent, config: config, settings: settings, runService: RunService(fluent: fluent))
            let films = try await eval.labelledFilms()
            #expect(films.count == 1 && films[0].positives == ["cat-and-mouse"] && films[0].negatives == ["ha-ha-ha"])
            // A film with no decision and no tag has nothing to judge.
            try await Movie(jellyfinId: "jf-none").save(on: fluent.db())
            await #expect(throws: VerifyError.self) { _ = try await verify.save(jellyfinId: "jf-none", wrong: []) }
        }
    }

    /// A watched film with no mood: the card shows what AI considered, the owner adds one of them
    /// and one of their own; the rest of what AI considered become negatives.
    @Test func untaggedWatchedFilmsTakeTheOwnersPicks() async throws {
        try await withTestFluent { fluent in
            let movie = Movie(jellyfinId: "jf-w")
            movie.played = true
            try await movie.save(on: fluent.db())
            try await Movie(jellyfinId: "jf-u").save(on: fluent.db())
            let reader = ScriptedReader(answer: answer([candidate("cat-and-mouse", 0.7, evidence: "chase"), candidate("ha-ha-ha", 0.65, evidence: "gags")]))
            // The grader backs neither, so nothing is applied and the film is unsure.
            let classifier = ScriptedClassifier(answer: classifierAnswer(["cat-and-mouse": 0.3, "ha-ha-ha": 0.2], primary: "none"))
            let (pipeline, movies, settings) = try await makePipeline(fluent, config: config, enricher: ScriptedEnricher(), reader: reader, classifier: classifier)
            for id in ["jf-w", "jf-u"] { _ = try await pipeline.tag(jellyfinId: id, trigger: .manual) }
            #expect(try await tagSlugs(fluent, "jf-w").isEmpty)
            let verify = VerifyService(fluent: fluent, config: config, movies: movies, logger: Logger(label: "test"))

            let sample = try await verify.sample(count: 5, seed: "x", scope: .watched, mode: .untagged)
            #expect(sample.films.map(\.jellyfinId) == ["jf-w"])
            #expect(sample.counts == ["watched.tagged": 0, "watched.untagged": 1, "all.tagged": 0, "all.untagged": 2])
            #expect(sample.films[0].moods.isEmpty && sample.films[0].candidates.map(\.slug) == ["cat-and-mouse", "ha-ha-ha"])
            #expect(sample.films[0].candidates[0].evidence == "chase" && sample.films[0].candidates[0].probability == 0.3)

            let saved = try await verify.save(jellyfinId: "jf-w", wrong: [], add: ["cat-and-mouse", "quiet-epics", "not-a-mood"])
            #expect(saved.added == ["cat-and-mouse", "quiet-epics"] && saved.kept.isEmpty)
            #expect(saved.tally == VerifyService.Tally(films: 1, judged: 0, right: 0, wrong: 0))  // nothing AI applied was judged
            #expect(try await tagSlugs(fluent, "jf-w") == ["cat-and-mouse:user", "quiet-epics:user"])
            #expect(try await TagSuggestion.query(on: fluent.db()).filter(\.$jellyfinId == "jf-w").filter(\.$status == "pending").count() == 0)
            let eval = EvalService(fluent: fluent, config: config, settings: settings, runService: RunService(fluent: fluent))
            let films = try await eval.labelledFilms()
            #expect(films.count == 1 && films[0].positives == ["cat-and-mouse", "quiet-epics"] && films[0].negatives == ["ha-ha-ha"])
            // Judged, so it leaves the pool; "none fits" on a film with candidates is a verdict too.
            #expect(try await verify.sample(count: 5, seed: "x", scope: .watched, mode: .untagged).films.isEmpty)
            _ = try await verify.save(jellyfinId: "jf-u", wrong: [], add: [])
            #expect(try await verify.sample(count: 5, seed: "x", scope: .all, mode: .untagged).remaining == 0)
        }
    }
}
