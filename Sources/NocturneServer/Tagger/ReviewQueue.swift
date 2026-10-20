import FluentKit
import Foundation
import HummingbirdFluent
import Logging

/// The admin's review queue over `tag_suggestions`. Every human action marks the row
/// `resolved_by = user` and the film's tags `label_source = user`, which is what makes them
/// ground truth for calibration and the eval.
final class ReviewQueue: @unchecked Sendable {
    let fluent: Fluent
    let config: NocturneConfiguration
    let movies: MovieService
    let pipeline: TaggerPipeline
    let logger: Logger

    init(fluent: Fluent, config: NocturneConfiguration, movies: MovieService, pipeline: TaggerPipeline, logger: Logger = Logger(label: "Review")) {
        self.fluent = fluent
        self.config = config
        self.movies = movies
        self.pipeline = pipeline
        self.logger = logger
    }

    func listPending() async throws -> [TagSuggestion] {
        try await TagSuggestion.query(on: fluent.db())
            .filter(\.$status == "pending")
            .sort(\.$createdAt, .descending)
            .all()
    }

    func list(status: String) async throws -> [TagSuggestion] {
        try await TagSuggestion.query(on: fluent.db())
            .filter(\.$status == status)
            .sort(\.$createdAt, .descending)
            .all()
    }

    func pendingJellyfinIds() async throws -> Set<String> {
        let rows = try await TagSuggestion.query(on: fluent.db())
            .filter(\.$status == "pending")
            .field(\.$jellyfinId)
            .all()
        return Set(rows.map(\.jellyfinId))
    }

    /// Approve. Without `overrideTags` the applied tags are confirmed as the admin's; with them,
    /// the admin's edited set replaces the film's tags. Legacy removal rows drop their tag.
    func approve(_ id: UUID, overrideTags: [String]? = nil) async throws -> TagSuggestion {
        let db = fluent.db()
        guard let sugg = try await TagSuggestion.find(id, on: db) else { throw TaggerError.notFound(id) }
        guard sugg.status == "pending" else { throw TaggerError.alreadyResolved(id) }

        if sugg.kind == "removal" {
            if let slug = sugg.removalTagSlug, !slug.isEmpty {
                try await movies.removeAutoTags(jellyfinId: sugg.jellyfinId, tagSlugs: [slug])
            }
        } else if let overrideTags {
            let valid = overrideTags.filter { config.moodBuckets[$0] != nil }
            _ = try await movies.updateMovieTags(jellyfinId: sugg.jellyfinId, tagSlugs: valid, replaceAll: true, labelSource: .user)
            sugg.suggestedTags = valid
        } else {
            try await movies.promoteAutoTagsToUser(jellyfinId: sugg.jellyfinId)
        }

        sugg.status = "approved"
        sugg.resolvedAt = Date()
        sugg.resolvedBy = ResolvedBy.user
        try await sugg.save(on: db)
        return sugg
    }

    /// Reject. Additive rows lose the tags the tagger applied; the admin's own tags stay.
    func reject(_ id: UUID) async throws -> TagSuggestion {
        let db = fluent.db()
        guard let sugg = try await TagSuggestion.find(id, on: db) else { throw TaggerError.notFound(id) }
        guard sugg.status == "pending" else { throw TaggerError.alreadyResolved(id) }
        if sugg.kind != "removal" {
            try await movies.removeAutoTags(jellyfinId: sugg.jellyfinId, tagSlugs: sugg.suggestedTags)
        }
        sugg.status = "rejected"
        sugg.resolvedAt = Date()
        sugg.resolvedBy = ResolvedBy.user
        try await sugg.save(on: db)
        return sugg
    }

    /// Drops the tagger's earlier tags on the film, clears pending rows, and tags again.
    func regenerate(jellyfinId: String) async throws -> TagSuggestion {
        let db = fluent.db()
        let prior = try await TagSuggestion.query(on: db).filter(\.$jellyfinId == jellyfinId).all().flatMap(\.suggestedTags)
        let unique = Array(Set(prior))
        if !unique.isEmpty {
            try await movies.removeAutoTags(jellyfinId: jellyfinId, tagSlugs: unique)
        }
        try await TagSuggestion.query(on: db)
            .filter(\.$jellyfinId == jellyfinId)
            .filter(\.$status == "pending")
            .delete()
        return try await pipeline.tag(jellyfinId: jellyfinId, trigger: .manual, replaceExistingPending: true)
    }
}
