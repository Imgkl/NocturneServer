import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import Testing

@testable import NocturneServer

/// Scripted enrichment: each film id maps to a row shape or a thrown error.
private final class FakeEnriching: Enriching, @unchecked Sendable {
    enum Script: Sendable {
        case row(source: EnrichmentSource, plot: Bool, resolved: Bool)
        case authFailure
        case failure
    }

    var scripts: [String: Script]
    var defaultScript: Script = .row(source: .wikipedia, plot: true, resolved: true)
    var delayMs: Int = 0
    private let lock = NSLock()
    private var seen: [String] = []
    var onCall: (@Sendable (Int) async -> Void)? = nil

    init(_ scripts: [String: Script] = [:]) { self.scripts = scripts }

    var calls: [String] { lock.withLock { seen } }

    func enrich(jellyfinId: String, item: BaseItemDto?, force: Bool, context: CallContext) async throws -> MovieEnrichment {
        let n = lock.withLock { seen.append(jellyfinId); return seen.count }
        if let onCall { await onCall(n) }
        if delayMs > 0 { try? await Task.sleep(for: .milliseconds(delayMs)) }
        switch scripts[jellyfinId] ?? defaultScript {
        case .authFailure:
            throw OutboundError.authFailure(provider: "wikidata", status: 403)
        case .failure:
            throw OutboundError.transport(provider: "wikimedia", underlying: "reset")
        case .row(let source, let plot, let resolved):
            let row = MovieEnrichment(jellyfinId: jellyfinId)
            row.source = source.rawValue
            row.plotFound = plot
            row.textBlock = "block"
            if resolved { row.wikidataQid = "Q1" }
            return row
        }
    }
}

@Suite struct EnrichCoverageJobTests {

    private func ids(_ n: Int) -> [String] { (1...n).map { "jf-\($0)" } }

    @Test func countsBucketsAndFinishesDone() async throws {
        try await withTestFluent { fluent in
            let runs = RunService(fluent: fluent, logger: Logger(label: "test"))
            let fake = FakeEnriching([
                "jf-2": .row(source: .wikipediaOtherLang, plot: true, resolved: true),
                "jf-3": .row(source: .none, plot: false, resolved: true),
                "jf-4": .row(source: .none, plot: false, resolved: false),
                "jf-5": .failure,
            ])
            let job = EnrichCoverageJob(runService: runs, enrichment: fake, fluent: fluent, concurrency: 3, logger: Logger(label: "test"))
            let run = try await runs.start(kind: .enrichCoverage, trigger: .manual, total: 6)
            await job.run(runId: try run.requireID(), ids: ids(6))

            let finished = try #require(try await runs.get(try run.requireID()))
            #expect(finished.status == "done")
            #expect(finished.processed == 6)
            let stats = RunService.stats(of: finished)
            #expect(stats["english_plot"] == 2)
            #expect(stats["other_lang_plot"] == 1)
            #expect(stats["no_plot"] == 1)
            #expect(stats["unresolved"] == 1)
            #expect(stats["error"] == 1)
            #expect(Set(fake.calls) == Set(ids(6)))
        }
    }

    @Test func cancelStopsClaimingNewFilms() async throws {
        try await withTestFluent { fluent in
            let runs = RunService(fluent: fluent, logger: Logger(label: "test"))
            let fake = FakeEnriching()
            let run = try await runs.start(kind: .enrichCoverage, trigger: .manual, total: 20)
            let runId = try run.requireID()
            fake.onCall = { n in
                if n == 5 { try? await runs.requestCancel(runId) }
            }
            let job = EnrichCoverageJob(runService: runs, enrichment: fake, fluent: fluent, concurrency: 3, logger: Logger(label: "test"))
            await job.run(runId: runId, ids: ids(20))

            let finished = try #require(try await runs.get(runId))
            #expect(finished.status == "cancelled")
            #expect(fake.calls.count >= 5 && fake.calls.count <= 8)
        }
    }

    @Test func authFailureAbortsTheRun() async throws {
        try await withTestFluent { fluent in
            let runs = RunService(fluent: fluent, logger: Logger(label: "test"))
            let fake = FakeEnriching(["jf-4": .authFailure])
            let job = EnrichCoverageJob(runService: runs, enrichment: fake, fluent: fluent, concurrency: 3, logger: Logger(label: "test"))
            let run = try await runs.start(kind: .enrichCoverage, trigger: .manual, total: 20)
            await job.run(runId: try run.requireID(), ids: ids(20))

            let finished = try #require(try await runs.get(try run.requireID()))
            #expect(finished.status == "error")
            #expect(finished.error == "auth")
            #expect(fake.calls.count <= 6)
        }
    }

    @Test func bucketsAndSummary() async throws {
        try await withTestFluent { fluent in
            let english = MovieEnrichment(jellyfinId: "a"); english.source = "wikipedia"; english.plotFound = true; english.wikidataQid = "Q1"
            let tamil = MovieEnrichment(jellyfinId: "b"); tamil.source = "wikipedia_other_lang"; tamil.plotFound = true; tamil.wikidataQid = "Q2"
            let noPlot = MovieEnrichment(jellyfinId: "c"); noPlot.wikiTitle = "Stub"
            let unresolved = MovieEnrichment(jellyfinId: "d")
            let failed = MovieEnrichment(jellyfinId: "e"); failed.error = "boom"
            let model = MovieEnrichment(jellyfinId: "f"); model.source = "model"; model.unverified = true; model.plotFound = true
            for row in [english, tamil, noPlot, unresolved, failed, model] { try await row.save(on: fluent.db()) }

            #expect(EnrichCoverageJob.bucket(for: english) == "english_plot")
            #expect(EnrichCoverageJob.bucket(for: tamil) == "other_lang_plot")
            #expect(EnrichCoverageJob.bucket(for: noPlot) == "no_plot")
            #expect(EnrichCoverageJob.bucket(for: unresolved) == "unresolved")
            #expect(EnrichCoverageJob.bucket(for: failed) == "error")
            #expect(EnrichCoverageJob.bucket(for: model) == "model_synopsis")

            let runs = RunService(fluent: fluent, logger: Logger(label: "test"))
            let job = EnrichCoverageJob(runService: runs, enrichment: FakeEnriching(), fluent: fluent, logger: Logger(label: "test"))
            let summary = try await job.summary()
            #expect(summary["total"] == 6)
            #expect(summary["unverified"] == 1)
            #expect(summary["english_plot"] == 1)
            #expect(try await job.worklist(filter: "no_plot").map(\.jellyfinId) == ["c"])
            #expect(try await job.worklist(filter: "unresolved").map(\.jellyfinId) == ["d"])
            #expect(try await job.worklist(filter: "error").map(\.jellyfinId) == ["e"])
            #expect(try await job.worklist(filter: "unverified").map(\.jellyfinId) == ["f"])
        }
    }
}
