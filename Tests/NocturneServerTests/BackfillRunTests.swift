import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import Testing

@testable import NocturneServer

@Suite struct BackfillRunTests {
    private let config = NocturneConfiguration()

    private func job(_ fluent: Fluent, reader: ScriptedReader) async throws -> (BackfillJob, RunService, TaggerPipeline, MovieService) {
        let (pipeline, movies, _) = try await makePipeline(fluent, config: config, enricher: ScriptedEnricher(), reader: reader)
        let runs = RunService(fluent: fluent, logger: Logger(label: "test"))
        let queue = ReviewQueue(fluent: fluent, config: config, movies: movies, pipeline: pipeline, logger: Logger(label: "test"))
        return (BackfillJob(runService: runs, pipeline: pipeline, queue: queue, fluent: fluent, config: config, logger: Logger(label: "test")), runs, pipeline, movies)
    }

    @Test func backfillCandidatesAreUntaggedOrPendingFilms() async throws {
        try await withTestFluent { fluent in
            for id in ["a", "b", "c"] { try await Movie(jellyfinId: id).save(on: fluent.db()) }
            let (job, _, _, movies) = try await job(fluent, reader: ScriptedReader(answer: answer([])))
            _ = try await movies.updateMovieTags(jellyfinId: "a", tagSlugs: ["cult-chaos"], replaceAll: false, labelSource: .user)
            _ = try await movies.updateMovieTags(jellyfinId: "b", tagSlugs: ["cult-chaos"], replaceAll: false, labelSource: .auto)
            try await TagSuggestion(jellyfinId: "b", suggestedTags: ["cult-chaos"], confidence: 0.5, reasoning: nil, status: "pending").save(on: fluent.db())
            #expect(try await job.candidates(for: .backfill).sorted() == ["b", "c"])
        }
    }

    @Test func reprocessAllKeepsUserTagsAndSupersedesPending() async throws {
        try await withTestFluent { fluent in
            for id in ["a", "b"] { try await Movie(jellyfinId: id).save(on: fluent.db()) }
            let (job, _, _, movies) = try await job(fluent, reader: ScriptedReader(answer: answer([])))
            _ = try await movies.updateMovieTags(jellyfinId: "a", tagSlugs: ["cult-chaos"], replaceAll: false, labelSource: .user)
            _ = try await movies.updateMovieTags(jellyfinId: "a", tagSlugs: ["heist-energy"], replaceAll: false, labelSource: .auto)
            _ = try await movies.updateMovieTags(jellyfinId: "b", tagSlugs: ["quiet-epics"], replaceAll: false, labelSource: .seed)
            let pending = TagSuggestion(jellyfinId: "b", suggestedTags: [], confidence: 0, reasoning: nil, status: "pending")
            try await pending.save(on: fluent.db())

            #expect(try await job.candidates(for: .reprocessAll).sorted() == ["a", "b"])
            #expect(try await tagSlugs(fluent, "a") == ["cult-chaos:user"])
            #expect(try await tagSlugs(fluent, "b").isEmpty)
            #expect(try await TagSuggestion.find(try pending.requireID(), on: fluent.db())?.status == "superseded")
        }
    }

    @Test func runProcessesSequentiallyWithStatsAndStatus() async throws {
        try await withTestFluent { fluent in
            for id in ["a", "b", "c"] { try await Movie(jellyfinId: id).save(on: fluent.db()) }
            let reader = ScriptedReader(answer: answer([candidate("cat-and-mouse", 0.95)]))
            let (job, runs, _, _) = try await job(fluent, reader: reader)
            let run = try await runs.start(kind: .backfill, trigger: .manual, total: 3)
            #expect(try await job.status().running)
            await job.run(runId: try run.requireID(), ids: ["a", "b", "c"], replaceExistingPending: true)
            let finished = try #require(try await runs.get(try run.requireID()))
            #expect(finished.status == "done")
            #expect(finished.processed == 3)
            #expect(RunService.stats(of: finished)["applied"] == 3)
            #expect(reader.calls == 3)
            let status = try await job.status()
            #expect(!status.running)
            #expect(status.processed == 3)
            #expect(try await Decision.query(on: fluent.db()).filter(\.$runId == run.id).count() == 3)
        }
    }

    @Test func cancelStopsWithinOneFilm() async throws {
        try await withTestFluent { fluent in
            for i in 1...10 { try await Movie(jellyfinId: "m\(i)").save(on: fluent.db()) }
            let reader = ScriptedReader(answer: answer([candidate("cat-and-mouse", 0.95)]))
            let (job, runs, _, _) = try await job(fluent, reader: reader)
            let run = try await runs.start(kind: .backfill, trigger: .manual, total: 10)
            let runId = try run.requireID()
            try await runs.requestCancel(runId)
            await job.run(runId: runId, ids: (1...10).map { "m\($0)" }, replaceExistingPending: true)
            #expect(reader.calls == 0)
            #expect(try await runs.get(runId)?.status == "cancelled")
        }
    }

    @Test func authFailureAbortsTheRun() async throws {
        try await withTestFluent { fluent in
            for i in 1...5 { try await Movie(jellyfinId: "m\(i)").save(on: fluent.db()) }
            let reader = ScriptedReader(answer: answer([]))
            reader.error = OutboundError.authFailure(provider: "anthropic", status: 401)
            let (job, runs, _, _) = try await job(fluent, reader: reader)
            let run = try await runs.start(kind: .backfill, trigger: .manual, total: 5)
            await job.run(runId: try run.requireID(), ids: (1...5).map { "m\($0)" }, replaceExistingPending: true)
            let finished = try #require(try await runs.get(try run.requireID()))
            #expect(finished.status == "error")
            #expect(finished.error == "auth")
            #expect(reader.calls == 1)
        }
    }

    @Test func otherErrorsMarkTheFilmAndContinue() async throws {
        try await withTestFluent { fluent in
            for i in 1...3 { try await Movie(jellyfinId: "m\(i)").save(on: fluent.db()) }
            let reader = ScriptedReader(answer: answer([]))
            reader.error = ReaderError.malformed("bad")
            let (job, runs, _, _) = try await job(fluent, reader: reader)
            let run = try await runs.start(kind: .backfill, trigger: .manual, total: 3)
            await job.run(runId: try run.requireID(), ids: ["m1", "m2", "m3"], replaceExistingPending: true)
            let finished = try #require(try await runs.get(try run.requireID()))
            #expect(finished.status == "done")
            #expect(RunService.stats(of: finished)["review"] == 3)   // empty pending rows for manual review
            #expect(reader.calls == 3)
        }
    }
}
