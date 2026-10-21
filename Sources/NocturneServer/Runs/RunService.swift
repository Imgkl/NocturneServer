import FluentKit
import Foundation
import HummingbirdFluent
import Logging

enum RunKind: String, Sendable, Codable {
    case backfill
    case reprocess
    case regrade
    case eval
    case enrichCoverage = "enrich-coverage"
    case teach
}

enum RunStatus: String, Sendable, Codable {
    case running
    case done
    case cancelled
    case error
}

enum RunError: Error, CustomStringConvertible {
    case busy(runningId: UUID, kind: String)
    case notFound(UUID)

    var description: String {
        switch self {
        case .busy(let id, let kind): return "a \(kind) run is already in progress (\(id))"
        case .notFound(let id): return "run \(id) not found"
        }
    }
}

/// Persisted progress, cancellation and completion for long-running jobs. One run at a time.
/// Everything lives in the `runs` table, so a restart loses nothing but the in-flight work,
/// which `markStaleOnBoot` turns into an `error` row with reason `stale`.
actor RunService {
    let fluent: Fluent
    let logger: Logger
    /// A `running` row whose heartbeat is older than this is considered dead on boot.
    let staleAfter: TimeInterval

    init(fluent: Fluent, logger: Logger = Logger(label: "Runs"), staleAfter: TimeInterval = 600) {
        self.fluent = fluent
        self.logger = logger
        self.staleAfter = staleAfter
    }

    // MARK: Lifecycle

    func running() async throws -> Run? {
        try await Run.query(on: fluent.db()).filter(\.$status == RunStatus.running.rawValue).first()
    }

    func start(kind: RunKind, trigger: RunTrigger, total: Int, params: [String: String] = [:]) async throws -> Run {
        if let active = try await running(), let id = active.id {
            throw RunError.busy(runningId: id, kind: active.kind)
        }
        let run = Run(kind: kind.rawValue, trigger: trigger.rawValue, total: total, paramsJson: Self.json(params))
        try await run.save(on: fluent.db())
        logger.info("run \(run.id?.uuidString ?? "?") started: \(kind.rawValue) (\(trigger.rawValue)), \(total) items")
        return run
    }

    func get(_ id: UUID) async throws -> Run? {
        try await Run.find(id, on: fluent.db())
    }

    func latest(kind: RunKind) async throws -> Run? {
        try await Run.query(on: fluent.db())
            .filter(\.$kind == kind.rawValue)
            .sort(\.$startedAt, .descending)
            .first()
    }

    /// Records progress. `stats` replaces the stored stats wholesale when given.
    func tick(_ id: UUID, processed: Int? = nil, total: Int? = nil, stats: [String: Int]? = nil) async throws {
        guard let run = try await get(id) else { throw RunError.notFound(id) }
        if let processed { run.processed = processed }
        if let total { run.total = total }
        if let stats { run.statsJson = Self.json(stats) }
        run.heartbeatAt = Date()
        try await run.save(on: fluent.db())
    }

    @discardableResult
    func requestCancel(_ id: UUID) async throws -> Bool {
        guard let run = try await get(id) else { throw RunError.notFound(id) }
        guard run.status == RunStatus.running.rawValue else { return false }
        run.cancelRequested = true
        try await run.save(on: fluent.db())
        return true
    }

    func isCancelled(_ id: UUID) async throws -> Bool {
        guard let run = try await get(id) else { return true }
        return run.cancelRequested || run.status != RunStatus.running.rawValue
    }

    func finish(_ id: UUID, status: RunStatus, error: String? = nil, stats: [String: Int]? = nil) async throws {
        guard let run = try await get(id) else { throw RunError.notFound(id) }
        run.status = status.rawValue
        run.error = error
        if let stats { run.statsJson = Self.json(stats) }
        run.finishedAt = Date()
        run.heartbeatAt = run.finishedAt
        run.costJson = Self.json(try await costByProvider(runId: id))
        try await run.save(on: fluent.db())
        logger.info("run \(id) finished: \(status.rawValue)\(error.map { " (\($0))" } ?? "")")
    }

    /// Ends the run as `error` and raises the cancel flag so workers stop claiming work.
    func abort(_ id: UUID, reason: String) async throws {
        guard let run = try await get(id) else { throw RunError.notFound(id) }
        run.cancelRequested = true
        try await run.save(on: fluent.db())
        try await finish(id, status: .error, error: reason)
    }

    /// Turns `running` rows whose heartbeat is older than `staleAfter` into `error` rows.
    /// Call once at boot. Returns the number of rows marked.
    @discardableResult
    func markStaleOnBoot(now: Date = Date()) async throws -> Int {
        let rows = try await Run.query(on: fluent.db()).filter(\.$status == RunStatus.running.rawValue).all()
        var marked = 0
        for run in rows {
            let last = run.heartbeatAt ?? run.startedAt ?? .distantPast
            guard now.timeIntervalSince(last) > staleAfter else { continue }
            run.status = RunStatus.error.rawValue
            run.error = "stale"
            run.finishedAt = now
            try await run.save(on: fluent.db())
            marked += 1
            logger.warning("run \(run.id?.uuidString ?? "?") (\(run.kind)) marked stale on boot")
        }
        return marked
    }

    // MARK: Views

    /// Per-provider spend for one run, from `api_calls`.
    func costByProvider(runId: UUID) async throws -> [String: Double] {
        let rows = try await ApiCall.query(on: fluent.db()).filter(\.$runId == runId).all()
        var out: [String: Double] = [:]
        for row in rows {
            out[row.provider, default: 0] += row.costUsd
        }
        return out
    }

    /// The legacy `/admin/auto-tag/backfill/status` shape, derived from the latest backfill,
    /// reprocess or regrade run (the three runs that share the tagger's job slot).
    func backfillStatus() async throws -> BackfillStatus {
        let latest = try await Run.query(on: fluent.db())
            .filter(\.$kind ~~ [RunKind.backfill.rawValue, RunKind.reprocess.rawValue, RunKind.regrade.rawValue])
            .sort(\.$startedAt, .descending)
            .first()
        guard let run = latest else {
            return BackfillStatus(running: false, total: 0, processed: 0, startedAt: nil, cancelled: nil, scope: nil)
        }
        let running = run.status == RunStatus.running.rawValue
        return BackfillStatus(
            running: running, total: run.total, processed: run.processed, startedAt: run.startedAt,
            cancelled: running ? run.cancelRequested : (run.status == RunStatus.cancelled.rawValue),
            scope: Self.params(of: run)["scope"], kind: run.kind)
    }

    static func params(of run: Run) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(run.paramsJson.utf8))) ?? [:]
    }

    static func stats(of run: Run) -> [String: Int] {
        (try? JSONDecoder().decode([String: Int].self, from: Data(run.statsJson.utf8))) ?? [:]
    }

    static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
