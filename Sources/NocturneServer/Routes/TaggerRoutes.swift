import Foundation
import Hummingbird
import Logging

/// Admin tagging routes: tag editor, manual tag, review queue, backfill. Same paths and
/// payloads as before the rewrite, so the web UI keeps working.
struct TaggerRoutes: @unchecked Sendable {
    let movies: MovieService
    let pipeline: TaggerPipeline
    let queue: ReviewQueue
    let backfill: BackfillJob
    let logger = Logger(label: "TaggerRoutes")

    struct ApproveBody: Codable { let tags: [String]? }
    struct ScopeBody: Codable { let scope: String? }
    struct BusyResponse: Codable {
        let error: String
        let runningId: UUID
    }

    func addRoutes(to api: RouterGroup<BasicRequestContext>) {
        let movieGroup = api.group("movies")

        // PUT /movies/:id/tags: the admin's tag editor. Writes label_source = user.
        movieGroup.put(":id/tags") { request, context in
            let movieId = try context.parameters.require("id")
            let update = try await request.decode(as: UpdateMovieTagsRequest.self, context: context)
            try update.validate()
            return try jsonResponse(
                try await self.movies.updateMovieTags(
                    jellyfinId: String(movieId), tagSlugs: update.tagSlugs, replaceAll: update.replaceAll, labelSource: .user))
        }

        // POST /movies/:id/auto-tag: tag one film now through the pipeline.
        movieGroup.post(":id/auto-tag") { _, context in
            let jellyfinId = try context.parameters.require("id")
            let sugg = try await self.pipeline.tag(jellyfinId: String(jellyfinId), trigger: .manual)
            return try jsonResponse(try await self.response(sugg))
        }

        let admin = api.group("admin")

        admin.get("suggestions") { request, _ in
            let status = request.uri.queryParameters["status"].map(String.init) ?? "pending"
            let rows = status == "pending" ? try await self.queue.listPending() : try await self.queue.list(status: status)
            let extras = try await self.queue.decisionExtras(for: rows)
            return try jsonResponse(SuggestionListResponse(items: rows.map { row in
                let extra = row.decisionId.flatMap { extras[$0] }
                return TagSuggestionResponse(row, source: extra?.source, alternates: extra?.alternates ?? [])
            }))
        }

        admin.post("suggestions/:id/approve") { request, context in
            guard let uuid = UUID(uuidString: String(try context.parameters.require("id"))) else { throw HTTPError(.badRequest) }
            let overrideTags = try? await request.decode(as: ApproveBody.self, context: context).tags
            return try jsonResponse(try await self.response(try await self.queue.approve(uuid, overrideTags: overrideTags)))
        }

        admin.post("suggestions/:id/reject") { _, context in
            guard let uuid = UUID(uuidString: String(try context.parameters.require("id"))) else { throw HTTPError(.badRequest) }
            return try jsonResponse(try await self.response(try await self.queue.reject(uuid)))
        }

        admin.post("suggestions/regenerate/:jellyfinId") { _, context in
            let jid = try context.parameters.require("jellyfinId")
            return try jsonResponse(try await self.response(try await self.queue.regenerate(jellyfinId: String(jid))))
        }

        admin.post("auto-tag/backfill") { request, context in
            let scope = try await self.scope(from: request, context: context)
            do {
                _ = try await self.backfill.start(mode: .backfill, trigger: .manual, scope: scope)
                return try jsonResponse(try await self.backfill.status())
            } catch RunError.busy(let runningId, let kind) {
                return try jsonResponse(BusyResponse(error: "a \(kind) run is already in progress", runningId: runningId), status: .conflict)
            }
        }

        admin.get("auto-tag/backfill/status") { _, _ in
            try jsonResponse(try await self.backfill.status())
        }

        admin.post("auto-tag/reprocess-all") { request, context in
            let scope = try await self.scope(from: request, context: context)
            do {
                _ = try await self.backfill.start(mode: .reprocessAll, trigger: .manual, scope: scope)
                return try jsonResponse(try await self.backfill.status())
            } catch RunError.busy(let runningId, let kind) {
                return try jsonResponse(BusyResponse(error: "a \(kind) run is already in progress", runningId: runningId), status: .conflict)
            }
        }

        // POST /admin/auto-tag/regrade: the classifier and the policy again over films with a stored reader answer.
        admin.post("auto-tag/regrade") { request, context in
            let scope = try await self.scope(from: request, context: context)
            do {
                _ = try await self.backfill.start(mode: .regrade, trigger: .manual, scope: scope)
                return try jsonResponse(try await self.backfill.status())
            } catch RunError.busy(let runningId, let kind) {
                return try jsonResponse(BusyResponse(error: "a \(kind) run is already in progress", runningId: runningId), status: .conflict)
            }
        }

        admin.post("auto-tag/cancel") { _, _ in
            try jsonResponse(try await self.backfill.cancel())
        }
    }

    /// Optional `{ "scope": "watched" }` body; an empty body means every film.
    private func scope(from request: Request, context: BasicRequestContext) async throws -> BackfillJob.Scope {
        guard let raw = (try? await request.decode(as: ScopeBody.self, context: context))?.scope else { return .all }
        guard let scope = BackfillJob.Scope(rawValue: raw) else { throw HTTPError(.badRequest, message: "scope must be all, watched or unwatched") }
        return scope
    }

    private func response(_ sugg: TagSuggestion) async throws -> TagSuggestionResponse {
        let extras = try await queue.decisionExtras(for: [sugg])
        let extra = sugg.decisionId.flatMap { extras[$0] }
        return TagSuggestionResponse(sugg, source: extra?.source, alternates: extra?.alternates ?? [])
    }
}
