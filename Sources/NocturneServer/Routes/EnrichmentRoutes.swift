import Foundation
import Hummingbird
import Logging

/// Admin routes for the story source: coverage run, worklist, per-film row, page override,
/// forced refresh. Registered under `/api/v1/admin/enrichment`. Nothing here is reachable from
/// the client group, so plot text never leaves the admin surface.
struct EnrichmentRoutes: Sendable {
    let enrichment: EnrichmentService
    let coverage: EnrichCoverageJob
    let runService: RunService
    let logger = Logger(label: "EnrichmentRoutes")

    struct CoverageStatus: Codable {
        let running: Bool
        let runId: UUID?
        let status: String?
        let total: Int
        let processed: Int
        let stats: [String: Int]
        let startedAt: Date?
        let finishedAt: Date?
        let cancelRequested: Bool
        let error: String?
    }

    struct EnrichmentRow: Codable {
        let jellyfinId: String
        let imdbId: String?
        let tmdbId: String?
        let wikidataQid: String?
        let wikiSite: String?
        let wikiTitle: String?
        let wikiTitleOverride: String?
        let source: String
        let unverified: Bool
        let plotFound: Bool
        let plotText: String?
        let receptionText: String?
        let awardsJson: String?
        let omdbAwards: String?
        let inputHash: String?
        let enrichVersion: Int
        let fetchedAt: Date?
        let error: String?
        let bucket: String

        init(_ row: MovieEnrichment, includeText: Bool) {
            jellyfinId = row.jellyfinId
            imdbId = row.imdbId
            tmdbId = row.tmdbId
            wikidataQid = row.wikidataQid
            wikiSite = row.wikiSite
            wikiTitle = row.wikiTitle
            wikiTitleOverride = row.wikiTitleOverride
            source = row.source
            unverified = row.unverified
            plotFound = row.plotFound
            plotText = includeText ? row.plotText : nil
            receptionText = includeText ? row.receptionText : nil
            awardsJson = row.awardsJson
            omdbAwards = row.omdbAwards
            inputHash = row.inputHash
            enrichVersion = row.enrichVersion
            fetchedAt = row.fetchedAt
            error = row.error
            bucket = EnrichCoverageJob.bucket(for: row)
        }
    }

    struct WorklistResponse: Codable { let items: [EnrichmentRow] }
    struct OverrideBody: Codable {
        let wiki_site: String
        let wiki_title: String
    }
    struct BusyResponse: Codable {
        let error: String
        let runningId: UUID
    }

    func addRoutes(to api: RouterGroup<BasicRequestContext>) {
        let group = api.group("admin").group("enrichment")

        group.post("coverage") { _, _ in
            do {
                let run = try await self.coverage.start(trigger: .manual)
                return try jsonResponse(self.status(from: run), status: .accepted)
            } catch RunError.busy(let runningId, let kind) {
                return try jsonResponse(BusyResponse(error: "a \(kind) run is already in progress", runningId: runningId), status: .conflict)
            }
        }

        group.get("coverage/status") { _, _ in
            let run = try await self.runService.latest(kind: .enrichCoverage)
            return try jsonResponse(self.status(from: run))
        }

        group.post("coverage/cancel") { _, _ in
            if let run = try await self.runService.latest(kind: .enrichCoverage), let id = run.id {
                _ = try await self.runService.requestCancel(id)
            }
            let run = try await self.runService.latest(kind: .enrichCoverage)
            return try jsonResponse(self.status(from: run))
        }

        group.get("summary") { _, _ in
            try jsonResponse(try await self.coverage.summary())
        }

        group.get("worklist") { request, _ in
            let filter = request.uri.queryParameters["filter"].map(String.init) ?? "no_plot"
            let rows = try await self.coverage.worklist(filter: filter)
            return try jsonResponse(WorklistResponse(items: rows.map { EnrichmentRow($0, includeText: false) }))
        }

        group.get(":jellyfinId") { _, context in
            let id = String(try context.parameters.require("jellyfinId"))
            guard let row = try await self.enrichment.current(jellyfinId: id) else {
                return try jsonResponse(["error": "no enrichment row for \(id)"], status: .notFound)
            }
            return try jsonResponse(EnrichmentRow(row, includeText: true))
        }

        group.put(":jellyfinId/page") { request, context in
            let id = String(try context.parameters.require("jellyfinId"))
            let body = try await request.decode(as: OverrideBody.self, context: context)
            let row = try await self.enrichment.override(jellyfinId: id, site: body.wiki_site, title: body.wiki_title)
            return try jsonResponse(EnrichmentRow(row, includeText: true))
        }

        group.post(":jellyfinId/refresh") { _, context in
            let id = String(try context.parameters.require("jellyfinId"))
            let row = try await self.enrichment.enrich(jellyfinId: id, force: true)
            return try jsonResponse(EnrichmentRow(row, includeText: true))
        }
    }

    private func status(from run: Run?) -> CoverageStatus {
        guard let run else {
            return CoverageStatus(running: false, runId: nil, status: nil, total: 0, processed: 0, stats: [:], startedAt: nil, finishedAt: nil, cancelRequested: false, error: nil)
        }
        return CoverageStatus(
            running: run.status == RunStatus.running.rawValue, runId: run.id, status: run.status,
            total: run.total, processed: run.processed, stats: RunService.stats(of: run),
            startedAt: run.startedAt, finishedAt: run.finishedAt, cancelRequested: run.cancelRequested, error: run.error)
    }
}
