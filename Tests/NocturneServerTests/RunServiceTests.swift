import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import Testing

@testable import NocturneServer

@Suite struct RunServiceTests {

    @Test func startTickCancelFinish() async throws {
        try await withTestFluent { fluent in
            let runs = RunService(fluent: fluent, logger: Logger(label: "test"))
            let run = try await runs.start(kind: .enrichCoverage, trigger: .manual, total: 10)
            let id = try run.requireID()
            #expect(run.status == "running")
            #expect(try await runs.running()?.id == id)

            await #expect(throws: RunError.self) {
                _ = try await runs.start(kind: .backfill, trigger: .manual, total: 1)
            }

            try await runs.tick(id, processed: 3, stats: ["english_plot": 2, "no_plot": 1])
            let ticked = try #require(try await runs.get(id))
            #expect(ticked.processed == 3)
            #expect(RunService.stats(of: ticked) == ["english_plot": 2, "no_plot": 1])
            #expect(ticked.heartbeatAt != nil)

            #expect(try await !runs.isCancelled(id))
            #expect(try await runs.requestCancel(id))
            #expect(try await runs.isCancelled(id))

            try await runs.finish(id, status: .cancelled, stats: ["english_plot": 2, "no_plot": 1])
            let done = try #require(try await runs.get(id))
            #expect(done.status == "cancelled")
            #expect(done.finishedAt != nil)
            #expect(try await runs.running() == nil)
            #expect(try await !runs.requestCancel(id))

            // A new run can start once the previous one finished.
            let second = try await runs.start(kind: .backfill, trigger: .scheduled, total: 1)
            #expect(try await runs.latest(kind: .backfill)?.id == second.id)
        }
    }

    @Test func abortEndsRunAsErrorAndStopsClaims() async throws {
        try await withTestFluent { fluent in
            let runs = RunService(fluent: fluent, logger: Logger(label: "test"))
            let id = try await runs.start(kind: .backfill, trigger: .realtime, total: 5).requireID()
            try await runs.abort(id, reason: "auth")
            let run = try #require(try await runs.get(id))
            #expect(run.status == "error")
            #expect(run.error == "auth")
            #expect(try await runs.isCancelled(id))
        }
    }

    @Test func staleRunsAreMarkedOnBoot() async throws {
        try await withTestFluent { fluent in
            let runs = RunService(fluent: fluent, logger: Logger(label: "test"), staleAfter: 600)
            let fresh = try await runs.start(kind: .backfill, trigger: .manual, total: 1)
            #expect(try await runs.markStaleOnBoot(now: Date()) == 0)
            #expect(try await runs.get(try fresh.requireID())?.status == "running")

            let later = Date().addingTimeInterval(601)
            #expect(try await runs.markStaleOnBoot(now: later) == 1)
            let marked = try #require(try await runs.get(try fresh.requireID()))
            #expect(marked.status == "error")
            #expect(marked.error == "stale")
            #expect(try await runs.running() == nil)
        }
    }

    @Test func costByProviderAndBackfillStatusView() async throws {
        try await withTestFluent { fluent in
            let runs = RunService(fluent: fluent, logger: Logger(label: "test"))
            #expect(try await runs.backfillStatus().running == false)

            let run = try await runs.start(kind: .backfill, trigger: .manual, total: 40)
            let id = try run.requireID()
            for (provider, cost) in [("anthropic", 0.01), ("anthropic", 0.02), ("wikimedia", 0.0)] {
                try await ApiCall(runId: id, decisionId: nil, provider: provider, endpoint: "/", model: nil, attempt: 1, httpStatus: 200, durationMs: 1, unitsJson: "{}", costUsd: cost).save(on: fluent.db())
            }
            try await runs.tick(id, processed: 12)

            let status = try await runs.backfillStatus()
            #expect(status.running)
            #expect(status.total == 40)
            #expect(status.processed == 12)
            #expect(status.cancelled == false)

            try await runs.finish(id, status: .done)
            let finished = try #require(try await runs.get(id))
            let cost = try JSONDecoder().decode([String: Double].self, from: Data(finished.costJson.utf8))
            #expect(abs((cost["anthropic"] ?? 0) - 0.03) < 1e-9)
            #expect(cost["wikimedia"] == 0)
            #expect(try await runs.backfillStatus().running == false)
        }
    }
}
