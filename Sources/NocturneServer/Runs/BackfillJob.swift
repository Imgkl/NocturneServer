import FluentKit
import Foundation
import HummingbirdFluent
import Logging

/// Backfill (films with no tags or a pending review) and reprocess-all (every film, after
/// clearing the tagger's own tags) over `RunService`. Sequential: one reader call at a time.
final class BackfillJob: @unchecked Sendable {
    enum Mode: Sendable {
        case backfill
        case reprocessAll

        var kind: RunKind { self == .backfill ? .backfill : .reprocess }
    }

    /// Which films a run covers. `watched` is the admin's baseline: films they have seen and can
    /// judge at a glance, so their corrections become the first ground truth.
    enum Scope: String, Sendable {
        case all
        case watched
        case unwatched

        func includes(_ movie: Movie) -> Bool {
            switch self {
            case .all: return true
            case .watched: return movie.played
            case .unwatched: return !movie.played
            }
        }
    }

    let runService: RunService
    let pipeline: TaggerPipeline
    let queue: ReviewQueue
    let fluent: Fluent
    let config: NocturneConfiguration
    let logger: Logger

    init(runService: RunService, pipeline: TaggerPipeline, queue: ReviewQueue, fluent: Fluent, config: NocturneConfiguration, logger: Logger = Logger(label: "Backfill")) {
        self.runService = runService
        self.pipeline = pipeline
        self.queue = queue
        self.fluent = fluent
        self.config = config
        self.logger = logger
    }

    /// Starts in the background and returns the run. Throws `RunError.busy` when another run is active.
    func start(mode: Mode, trigger: RunTrigger, scope: Scope = .all) async throws -> Run {
        let ids = try await candidates(for: mode, scope: scope)
        let run = try await runService.start(kind: mode.kind, trigger: trigger, total: ids.count, params: ["scope": scope.rawValue])
        let runId = try run.requireID()
        Task.detached { [self] in
            await self.run(runId: runId, ids: ids, replaceExistingPending: true)
        }
        return run
    }

    /// Films to process, within the scope. Reprocess-all first detaches every tag the tagger wrote
    /// (never the admin's) on those films and supersedes their pending rows, so they start clean.
    func candidates(for mode: Mode, scope: Scope = .all) async throws -> [String] {
        let db = fluent.db()
        let all = try await Movie.query(on: db).with(\.$tags).all().filter(scope.includes)
        switch mode {
        case .backfill:
            let pending = try await queue.pendingJellyfinIds()
            return all.filter { $0.tags.isEmpty || pending.contains($0.jellyfinId) }.map(\.jellyfinId)
        case .reprocessAll:
            let movieIds = all.compactMap(\.id)
            let jellyfinIds = all.map(\.jellyfinId)
            if !movieIds.isEmpty {
                try await MovieTag.query(on: db)
                    .filter(\.$movie.$id ~~ movieIds)
                    .filter(\.$labelSource != LabelSource.user.rawValue)
                    .delete()
            }
            let oldPending = try await TagSuggestion.query(on: db)
                .filter(\.$status == "pending")
                .filter(\.$jellyfinId ~~ jellyfinIds)
                .all()
            let now = Date()
            for old in oldPending {
                old.status = "superseded"
                old.resolvedAt = now
                try await old.save(on: db)
            }
            return jellyfinIds
        }
    }

    /// The loop. Calibration is built once per run. A credentials failure aborts the whole run;
    /// any other failure marks the film and continues.
    func run(runId: UUID, ids: [String], replaceExistingPending: Bool) async {
        let titles = await pipeline.titles()
        let calibration = (try? await buildCalibration(fluent: fluent, titles: titles, availableTags: config.moodBuckets)) ?? [:]
        var processed = 0
        var stats: [String: Int] = ["applied": 0, "review": 0, "error": 0, "skipped": 0]

        for id in ids {
            if (try? await runService.isCancelled(runId)) ?? true { break }
            do {
                let sugg = try await pipeline.tag(
                    jellyfinId: id, trigger: .manual, replaceExistingPending: replaceExistingPending,
                    calibration: calibration, runId: runId)
                stats[sugg.status == "pending" ? "review" : "applied", default: 0] += 1
            } catch let error as OutboundError where error.isAuthFailure {
                logger.error("backfill: aborting on auth failure: \(error)")
                try? await runService.abort(runId, reason: "auth")
                return
            } catch {
                logger.warning("backfill: \(id) failed: \(error)")
                stats["error", default: 0] += 1
            }
            processed += 1
            try? await runService.tick(runId, processed: processed, stats: stats)
        }

        let cancelled = (try? await runService.isCancelled(runId)) ?? false
        try? await runService.finish(runId, status: cancelled ? .cancelled : .done, stats: stats)
    }

    func status() async throws -> BackfillStatus {
        try await runService.backfillStatus()
    }

    func cancel() async throws -> BackfillStatus {
        if let run = try await runService.running(), let id = run.id {
            _ = try await runService.requestCancel(id)
        }
        return try await runService.backfillStatus()
    }
}
