import Foundation

/// Spaces calls at least `1 / perSecond` apart. Callers `await acquire()` before each call.
/// Used for Wikimedia (2 requests per second per wiki).
actor RateLimiter {
    private let interval: Duration
    private var nextAllowed: ContinuousClock.Instant

    init(perSecond: Double) {
        precondition(perSecond > 0)
        self.interval = .seconds(1.0 / perSecond)
        self.nextAllowed = .now
    }

    func acquire() async throws {
        let now = ContinuousClock.now
        let slot = max(now, nextAllowed)
        nextAllowed = slot + interval
        if slot > now {
            try await Task.sleep(until: slot, clock: .continuous)
        }
    }
}
