import FluentKit
import Foundation
import HummingbirdFluent
import Logging

/// Seam over `EnrichmentService` so the coverage job can be tested with a fake.
protocol Enriching: Sendable {
    func enrich(jellyfinId: String, item: BaseItemDto?, force: Bool, context: CallContext) async throws -> MovieEnrichment
}

extension EnrichmentService: Enriching {}

/// Resolves and fetches every film in the library without any model call, and reports how
/// many have an English plot, an other-language plot, no plot, or no page at all. The admin's
/// worklist for page overrides comes from the same rows.
final class EnrichCoverageJob: Sendable {
    static let statKeys = ["english_plot", "other_lang_plot", "model_synopsis", "no_plot", "unresolved", "error"]

    let runService: RunService
    let enrichment: Enriching
    let fluent: Fluent
    let concurrency: Int
    let logger: Logger

    init(runService: RunService, enrichment: Enriching, fluent: Fluent, concurrency: Int = 3, logger: Logger = Logger(label: "Coverage")) {
        self.runService = runService
        self.enrichment = enrichment
        self.fluent = fluent
        self.concurrency = max(1, concurrency)
        self.logger = logger
    }

    /// Starts the job in the background and returns its run row at once.
    func start(trigger: RunTrigger) async throws -> Run {
        let ids = try await Movie.query(on: fluent.db()).all().map(\.jellyfinId)
        let run = try await runService.start(kind: .enrichCoverage, trigger: trigger, total: ids.count)
        let runId = try run.requireID()
        Task.detached { [self] in
            await self.run(runId: runId, ids: ids)
        }
        return run
    }

    /// The loop itself. Public so tests can drive it to completion.
    func run(runId: UUID, ids: [String]) async {
        var stats: [String: Int] = Dictionary(uniqueKeysWithValues: Self.statKeys.map { ($0, 0) })
        var processed = 0
        var aborted = false
        let context = CallContext(runId: runId)

        await withTaskGroup(of: (bucket: String, auth: Bool).self) { group in
            var next = ids.makeIterator()
            var inFlight = 0

            func claim() async -> Bool {
                guard !aborted, let id = next.next() else { return false }
                if (try? await runService.isCancelled(runId)) ?? true { return false }
                group.addTask { [self] in
                    await self.process(id, context: context)
                }
                inFlight += 1
                return true
            }

            for _ in 0..<concurrency {
                if !(await claim()) { break }
            }
            while inFlight > 0, let result = await group.next() {
                inFlight -= 1
                processed += 1
                stats[result.bucket, default: 0] += 1
                if result.auth {
                    aborted = true
                    try? await runService.abort(runId, reason: "auth")
                } else {
                    try? await runService.tick(runId, processed: processed, stats: stats)
                    _ = await claim()
                }
            }
        }

        guard !aborted else { return }
        let cancelled = (try? await runService.isCancelled(runId)) ?? false
        try? await runService.finish(runId, status: cancelled ? .cancelled : .done, stats: stats)
    }

    private func process(_ id: String, context: CallContext) async -> (bucket: String, auth: Bool) {
        do {
            let row = try await enrichment.enrich(jellyfinId: id, item: nil, force: false, context: context)
            return (Self.bucket(for: row), false)
        } catch let error as OutboundError where error.isAuthFailure {
            logger.error("coverage: auth failure on \(id): \(error)")
            return ("error", true)
        } catch {
            logger.warning("coverage: \(id) failed: \(error)")
            return ("error", false)
        }
    }

    // MARK: Classification

    static func bucket(for row: MovieEnrichment) -> String {
        if row.error != nil, row.textBlock == nil { return "error" }
        switch row.enrichmentSource {
        case .wikipedia: return "english_plot"
        case .wikipediaOtherLang: return "other_lang_plot"
        case .model: return "model_synopsis"
        case .none:
            let resolved = row.wikidataQid != nil || row.wikiTitle != nil || row.wikiTitleOverride != nil
            return resolved ? "no_plot" : "unresolved"
        }
    }

    static func stats(for rows: [MovieEnrichment]) -> [String: Int] {
        var out: [String: Int] = Dictionary(uniqueKeysWithValues: statKeys.map { ($0, 0) })
        for row in rows { out[bucket(for: row), default: 0] += 1 }
        return out
    }

    /// Rows for the admin worklist: `no_plot`, `unresolved`, `other_lang`, `unverified`, `error`.
    func worklist(filter: String) async throws -> [MovieEnrichment] {
        let rows = try await MovieEnrichment.query(on: fluent.db()).all()
        switch filter {
        case "no_plot": return rows.filter { Self.bucket(for: $0) == "no_plot" }
        case "unresolved": return rows.filter { Self.bucket(for: $0) == "unresolved" }
        case "other_lang": return rows.filter { Self.bucket(for: $0) == "other_lang_plot" }
        case "unverified": return rows.filter(\.unverified)
        case "error": return rows.filter { $0.error != nil }
        default: return rows
        }
    }

    /// Library-wide summary from the stored rows (not from a run), for Settings.
    func summary() async throws -> [String: Int] {
        let rows = try await MovieEnrichment.query(on: fluent.db()).all()
        var stats = Self.stats(for: rows)
        stats["total"] = rows.count
        stats["unverified"] = rows.filter(\.unverified).count
        return stats
    }
}
