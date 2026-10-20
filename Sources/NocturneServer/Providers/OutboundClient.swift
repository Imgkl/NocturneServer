import AsyncHTTPClient
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import NIOCore

/// Which job and which decision an outbound call belongs to, for `api_calls` attribution.
struct CallContext: Sendable {
    var runId: UUID? = nil
    var decisionId: UUID? = nil

    static let none = CallContext()
}

enum OutboundError: Error, CustomStringConvertible, Sendable {
    /// 401 or 403. A bad key fails every call, so workers abort the whole run on this.
    case authFailure(provider: String, status: Int)
    /// Retries exhausted on 429, 529 or 5xx.
    case exhausted(provider: String, lastStatus: Int)
    /// Connection or timeout failure before any status came back.
    case transport(provider: String, underlying: String)
    /// Any other non-2xx status.
    case http(provider: String, status: Int, bodyPreview: String)

    var description: String {
        switch self {
        case .authFailure(let p, let s): return "\(p): authentication failed (HTTP \(s))"
        case .exhausted(let p, let s): return "\(p): retries exhausted (last HTTP \(s))"
        case .transport(let p, let u): return "\(p): transport error: \(u)"
        case .http(let p, let s, let b): return "\(p): HTTP \(s): \(b)"
        }
    }

    var isAuthFailure: Bool {
        if case .authFailure = self { return true }
        return false
    }
}

/// Every outbound HTTP call goes through here: retries with backoff, auth-failure
/// classification, and one `api_calls` row per attempt with units and cost. Never logs or
/// stores request or response bodies, headers or keys.
final class OutboundClient: Sendable {
    typealias Sleeper = @Sendable (Duration) async throws -> Void
    typealias Jitter = @Sendable () -> Double

    let transport: HTTPTransport
    let fluent: Fluent
    let prices: PriceTable
    let logger: Logger
    let maxRetries: Int
    private let sleeper: Sleeper
    private let jitter: Jitter

    init(
        transport: HTTPTransport,
        fluent: Fluent,
        prices: PriceTable = .current,
        logger: Logger = Logger(label: "Outbound"),
        maxRetries: Int = 5,
        sleeper: @escaping Sleeper = { try await Task.sleep(for: $0) },
        jitter: @escaping Jitter = { Double.random(in: 0..<0.5) }
    ) {
        self.transport = transport
        self.fluent = fluent
        self.prices = prices
        self.logger = logger
        self.maxRetries = maxRetries
        self.sleeper = sleeper
        self.jitter = jitter
    }

    /// Sends `request`, retrying 429, 529 and 5xx with 1, 2, 4, 8, 8 s plus jitter (honouring
    /// `Retry-After`), and returns the first 2xx response. 401 and 403 throw at once.
    /// `units` turns a response into billable units; it runs on every attempt, so it must cope
    /// with error bodies (return `.none` when the status is not 2xx).
    func send(
        provider: String,
        endpoint: String,
        model: String? = nil,
        request: HTTPClientRequest,
        timeout: TimeAmount = .seconds(45),
        context: CallContext = .none,
        units: @Sendable (OutboundResponse) -> CallUnits = { _ in .none }
    ) async throws -> OutboundResponse {
        var attempt = 0
        while true {
            attempt += 1
            let started = ContinuousClock.now
            let response: OutboundResponse
            do {
                response = try await transport.execute(request, timeout: timeout)
            } catch {
                let ms = elapsedMs(since: started)
                await record(provider: provider, endpoint: endpoint, model: model, attempt: attempt,
                             status: nil, ms: ms, units: .none, cost: 0, context: context)
                throw OutboundError.transport(provider: provider, underlying: String(describing: error))
            }

            let ms = elapsedMs(since: started)
            let u = units(response)
            let cost = prices.cost(provider: provider, model: model, units: u)
            await record(provider: provider, endpoint: endpoint, model: model, attempt: attempt,
                         status: response.status, ms: ms, units: u, cost: cost, context: context)

            switch response.status {
            case 200..<300:
                return response
            case 401, 403:
                logger.error("\(provider) \(endpoint): HTTP \(response.status), aborting (bad credentials)")
                throw OutboundError.authFailure(provider: provider, status: response.status)
            case 429, 529, 500..<600:
                if attempt > maxRetries {
                    throw OutboundError.exhausted(provider: provider, lastStatus: response.status)
                }
                let delay = retryDelay(attempt: attempt, retryAfter: response.header("retry-after"))
                logger.warning("\(provider) \(endpoint): HTTP \(response.status); retry \(attempt)/\(maxRetries) in \(delay)")
                try await sleeper(delay)
            default:
                throw OutboundError.http(
                    provider: provider, status: response.status,
                    bodyPreview: String(response.bodyText.prefix(300)))
            }
        }
    }

    /// 1, 2, 4, 8, 8 ... seconds plus jitter; a numeric `Retry-After` wins when present.
    func retryDelay(attempt: Int, retryAfter: String?) -> Duration {
        if let retryAfter, let seconds = Double(retryAfter.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
            return .seconds(seconds)
        }
        let base = min(8.0, pow(2.0, Double(attempt - 1)))
        return .seconds(base + jitter())
    }

    private func elapsedMs(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        let (seconds, attoseconds) = elapsed.components
        return Int(seconds * 1000) + Int(attoseconds / 1_000_000_000_000_000)
    }

    private func record(
        provider: String, endpoint: String, model: String?, attempt: Int,
        status: Int?, ms: Int, units: CallUnits, cost: Double, context: CallContext
    ) async {
        let unitsJson: String
        if let data = try? JSONEncoder().encode(units), let s = String(data: data, encoding: .utf8) {
            unitsJson = s
        } else {
            unitsJson = "{}"
        }
        let row = ApiCall(
            runId: context.runId, decisionId: context.decisionId, provider: provider, endpoint: endpoint,
            model: model, attempt: attempt, httpStatus: status, durationMs: ms, unitsJson: unitsJson,
            costUsd: cost)
        do {
            try await row.save(on: fluent.db())
        } catch {
            logger.error("api_calls write failed for \(provider) \(endpoint): \(error)")
        }
    }
}
