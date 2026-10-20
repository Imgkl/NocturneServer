import AsyncHTTPClient
import Foundation
import NIOCore

@testable import NocturneServer

/// Scripted HTTP transport. Each `execute` pops the next scripted outcome; the request is
/// recorded (URL, method, header names) so tests can assert on what was sent without
/// ever inspecting secrets.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    enum Outcome: Sendable {
        case response(status: Int, headers: [String: String] = [:], body: String = "")
        case failure(String)
    }

    struct RecordedRequest: Sendable {
        let url: String
        let method: String
        let headerNames: [String]
        let headers: [String: String]
        let body: Data?
    }

    private let lock = NSLock()
    private var outcomes: [Outcome]
    private(set) var requests: [RecordedRequest] = []

    init(_ outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    /// Convenience for a transport that always returns the same JSON body with 200.
    static func ok(json: String) -> FakeTransport {
        FakeTransport([.response(status: 200, headers: ["content-type": "application/json"], body: json)])
    }

    func execute(_ request: HTTPClientRequest, timeout: TimeAmount) async throws -> OutboundResponse {
        var bodyData: Data? = nil
        if let body = request.body {
            var buffer = try await body.collect(upTo: 16 * 1024 * 1024)
            bodyData = buffer.readData(length: buffer.readableBytes)
        }
        var headers: [String: String] = [:]
        for (name, value) in request.headers { headers[name.lowercased()] = value }
        let recorded = RecordedRequest(
            url: request.url, method: request.method.rawValue,
            headerNames: request.headers.map { $0.name.lowercased() }, headers: headers, body: bodyData)

        let outcome: Outcome = lock.withLock {
            requests.append(recorded)
            return outcomes.isEmpty ? Outcome.failure("no scripted outcome left") : outcomes.removeFirst()
        }

        switch outcome {
        case .response(let status, let headers, let body):
            var lowered: [String: String] = [:]
            for (k, v) in headers { lowered[k.lowercased()] = v }
            return OutboundResponse(status: status, headers: lowered, body: Data(body.utf8))
        case .failure(let message):
            throw FakeTransportError(message: message)
        }
    }

    var requestCount: Int {
        lock.withLock { requests.count }
    }
}

struct FakeTransportError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Records the delays an `OutboundClient` asked for instead of sleeping.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var delays: [Duration] = []

    func sleeper() -> OutboundClient.Sleeper {
        { [self] duration in
            lock.withLock { delays.append(duration) }
        }
    }

    var seconds: [Double] {
        let snapshot = lock.withLock { delays }
        return snapshot.map { d in
            let (s, attos) = d.components
            return Double(s) + Double(attos) / 1e18
        }
    }
}
