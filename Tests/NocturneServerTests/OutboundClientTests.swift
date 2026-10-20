import AsyncHTTPClient
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import Testing

@testable import NocturneServer

@Suite struct OutboundClientTests {

    private func request() -> HTTPClientRequest {
        var r = HTTPClientRequest(url: "https://example.test/v1/thing")
        r.method = .POST
        r.headers.add(name: "x-api-key", value: "sk-secret")
        r.body = .bytes(Data("{\"hello\":1}".utf8))
        return r
    }

    private func client(_ fluent: Fluent, _ transport: FakeTransport, sleeper: SleepRecorder) -> OutboundClient {
        OutboundClient(
            transport: transport, fluent: fluent, prices: .current, logger: Logger(label: "test"),
            sleeper: sleeper.sleeper(), jitter: { 0 })
    }

    @Test func retriesOn429ThenSucceedsHonouringRetryAfter() async throws {
        try await withTestFluent { fluent in
            let transport = FakeTransport([
                .response(status: 429, headers: ["Retry-After": "3"], body: "slow down"),
                .response(status: 200, body: "{\"ok\":true}"),
            ])
            let sleeps = SleepRecorder()
            let outbound = client(fluent, transport, sleeper: sleeps)

            let response = try await outbound.send(provider: "test", endpoint: "/v1/thing", request: request())
            #expect(response.status == 200)
            #expect(transport.requestCount == 2)
            #expect(sleeps.seconds == [3])

            let rows = try await ApiCall.query(on: fluent.db()).sort(\.$attempt).all()
            #expect(rows.count == 2)
            #expect(rows.map(\.attempt) == [1, 2])
            #expect(rows.map(\.httpStatus) == [429, 200])
        }
    }

    @Test func backsOffOneTwoFourWithoutRetryAfter() async throws {
        try await withTestFluent { fluent in
            let transport = FakeTransport([
                .response(status: 529), .response(status: 503), .response(status: 529),
                .response(status: 200, body: "{}"),
            ])
            let sleeps = SleepRecorder()
            let outbound = client(fluent, transport, sleeper: sleeps)

            _ = try await outbound.send(provider: "test", endpoint: "/v1/thing", request: request())
            #expect(sleeps.seconds == [1, 2, 4])
            #expect(transport.requestCount == 4)
        }
    }

    @Test func authFailureThrowsAtOnceWithOneRow() async throws {
        try await withTestFluent { fluent in
            let transport = FakeTransport([.response(status: 401, body: "{\"error\":\"bad key\"}")])
            let sleeps = SleepRecorder()
            let outbound = client(fluent, transport, sleeper: sleeps)

            await #expect(throws: OutboundError.self) {
                _ = try await outbound.send(provider: "anthropic", endpoint: "/v1/messages", request: request())
            }
            let rows = try await ApiCall.query(on: fluent.db()).all()
            #expect(rows.count == 1)
            #expect(rows.first?.httpStatus == 401)
            #expect(sleeps.seconds.isEmpty)
            #expect(transport.requestCount == 1)
        }
    }

    @Test func authFailureIsClassified() async throws {
        try await withTestFluent { fluent in
            let transport = FakeTransport([.response(status: 403)])
            let outbound = client(fluent, transport, sleeper: SleepRecorder())
            do {
                _ = try await outbound.send(provider: "jev", endpoint: "/v1/systemone", request: request())
                Issue.record("expected a throw")
            } catch let error as OutboundError {
                #expect(error.isAuthFailure)
            }
        }
    }

    @Test func exhaustsAfterFiveRetries() async throws {
        try await withTestFluent { fluent in
            let transport = FakeTransport(Array(repeating: .response(status: 429), count: 6))
            let sleeps = SleepRecorder()
            let outbound = client(fluent, transport, sleeper: sleeps)

            do {
                _ = try await outbound.send(provider: "test", endpoint: "/x", request: request())
                Issue.record("expected a throw")
            } catch let error as OutboundError {
                if case .exhausted(_, let status) = error { #expect(status == 429) } else { Issue.record("wrong error \(error)") }
            }
            #expect(transport.requestCount == 6)
            #expect(sleeps.seconds == [1, 2, 4, 8, 8])
            #expect(try await ApiCall.query(on: fluent.db()).count() == 6)
        }
    }

    @Test func transportErrorRecordsRowWithoutStatus() async throws {
        try await withTestFluent { fluent in
            let transport = FakeTransport([.failure("connection reset")])
            let outbound = client(fluent, transport, sleeper: SleepRecorder())

            do {
                _ = try await outbound.send(provider: "wikimedia", endpoint: "/w/api.php", request: request())
                Issue.record("expected a throw")
            } catch let error as OutboundError {
                if case .transport = error {} else { Issue.record("wrong error \(error)") }
            }
            let rows = try await ApiCall.query(on: fluent.db()).all()
            #expect(rows.count == 1)
            #expect(rows.first?.httpStatus == nil)
        }
    }

    @Test func nonRetryableStatusThrowsHttpError() async throws {
        try await withTestFluent { fluent in
            let transport = FakeTransport([.response(status: 400, body: "{\"error\":\"bad request\"}")])
            let outbound = client(fluent, transport, sleeper: SleepRecorder())
            do {
                _ = try await outbound.send(provider: "test", endpoint: "/x", request: request())
                Issue.record("expected a throw")
            } catch let error as OutboundError {
                if case .http(_, let status, let preview) = error {
                    #expect(status == 400)
                    #expect(preview.contains("bad request"))
                } else {
                    Issue.record("wrong error \(error)")
                }
            }
        }
    }

    @Test func unitsAndCostAreMeteredAndNoSecretsStored() async throws {
        try await withTestFluent { fluent in
            let transport = FakeTransport([.response(status: 200, body: "{}")])
            let outbound = client(fluent, transport, sleeper: SleepRecorder())
            let context = CallContext(runId: UUID(), decisionId: UUID())

            _ = try await outbound.send(
                provider: "anthropic", endpoint: "/v1/messages", model: "claude-haiku-5-5",
                request: request(), context: context
            ) { _ in CallUnits(inputTokens: 1_000, outputTokens: 300, cacheReadTokens: 9_000) }

            let row = try #require(try await ApiCall.query(on: fluent.db()).first())
            #expect(row.runId == context.runId)
            #expect(row.decisionId == context.decisionId)
            #expect(row.model == "claude-haiku-5-5")
            let units = try JSONDecoder().decode(CallUnits.self, from: Data(row.unitsJson.utf8))
            #expect(units.inputTokens == 1_000)
            #expect(units.cacheReadTokens == 9_000)
            // 1000 * 0.10 + 300 * 0.50 + 9000 * 0.01 = 100 + 150 + 90 = 340 micro-dollars
            #expect(abs(row.costUsd - 0.00034) < 1e-9)
            #expect(!row.unitsJson.contains("sk-secret"))
            #expect(!row.endpoint.contains("sk-secret"))
        }
    }
}
