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

    /// Pending rows for films that are still in the library. A row whose film is gone (legacy
    /// data from before deletes superseded them) stays in the table but out of the queue.
    func listPending() async throws -> [TagSuggestion] {
        let rows = try await TagSuggestion.query(on: fluent.db())
            .filter(\.$status == "pending")
            .sort(\.$createdAt, .descending)
            .all()
        let known = Set(try await Movie.query(on: fluent.db()).all().map(\.jellyfinId))
        return rows.filter { known.contains($0.jellyfinId) }
    }

    func list(status: String) async throws -> [TagSuggestion] {
        try await TagSuggestion.query(on: fluent.db())
            .filter(\.$status == status)
            .sort(\.$createdAt, .descending)
            .all()
    }

    /// What a suggestion response carries from its decision row: the enrichment source and the
    /// reader's alternates, so the review UI needs no second round trip.
    struct DecisionExtras: Sendable, Equatable {
        let source: String?
        let alternates: [String]
    }

    func decisionExtras(for rows: [TagSuggestion]) async throws -> [UUID: DecisionExtras] {
        let ids = rows.compactMap(\.decisionId)
        guard !ids.isEmpty else { return [:] }
        let decisions = try await Decision.query(on: fluent.db()).filter(\.$id ~~ ids).all()
        let known = Set(config.moodBuckets.keys)
        var out: [UUID: DecisionExtras] = [:]
        for decision in decisions {
            guard let id = decision.id else { continue }
            let models = (try? JSONDecoder().decode([String: String].self, from: Data(decision.modelsJson.utf8))) ?? [:]
            out[id] = DecisionExtras(source: models["enrichment_source"], alternates: Self.alternates(in: decision.readerJson, known: known))
        }
        return out
    }

    /// Enrichment source per decision id.
    func enrichmentSources(for rows: [TagSuggestion]) async throws -> [UUID: String] {
        try await decisionExtras(for: rows).compactMapValues(\.source)
    }

    /// The reader's alternates from the stored raw answer: known slugs only, in order, no repeats.
    static func alternates(in readerJson: String?, known: Set<String>) -> [String] {
        struct Raw: Decodable { let alternates: [String]? }
        guard let json = readerJson, let raw = try? JSONDecoder().decode(Raw.self, from: Data(json.utf8)) else { return [] }
        var seen = Set<String>()
        return (raw.alternates ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { known.contains($0) && seen.insert($0).inserted }
    }

    func pendingJellyfinIds() async throws -> Set<String> {
        let rows = try await TagSuggestion.query(on: fluent.db())
            .filter(\.$status == "pending")
            .field(\.$jellyfinId)
            .all()
        return Set(rows.map(\.jellyfinId))
    }

    /// The per-mood items stored on a row; empty for rows written before items existed.
    static func items(of row: TagSuggestion) -> [SuggestionItem] {
        guard let json = row.itemsJson, let items = try? JSONDecoder().decode([SuggestionItem].self, from: Data(json.utf8)) else { return [] }
        return items
    }

    /// Approve. Without `overrideTags` the applied tags are confirmed as the admin's (a regrade row
    /// first drops the moods its new decision no longer applies); with them, the admin's edited set
    /// replaces the tagger's tags while the admin's own earlier tags stay. Legacy removal rows drop their tag.
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
            try await movies.removeAutoTags(jellyfinId: sugg.jellyfinId, tagSlugs: try await movies.autoTagSlugs(jellyfinId: sugg.jellyfinId))
            _ = try await movies.updateMovieTags(jellyfinId: sugg.jellyfinId, tagSlugs: valid, replaceAll: false, labelSource: .user)
            sugg.suggestedTags = valid
        } else {
            let removals = Self.items(of: sugg).filter { $0.kind == .remove }.map(\.slug)
            try await movies.removeAutoTags(jellyfinId: sugg.jellyfinId, tagSlugs: removals)
            try await movies.promoteAutoTagsToUser(jellyfinId: sugg.jellyfinId)
        }

        sugg.status = "approved"
        sugg.resolvedAt = Date()
        sugg.resolvedBy = ResolvedBy.user
        try await sugg.save(on: db)
        return sugg
    }

    /// Reject. Additive rows lose the tags the tagger applied; a regrade row loses only what the
    /// regrade put on the film, so the film goes back to how it was; the admin's own tags stay.
    func reject(_ id: UUID) async throws -> TagSuggestion {
        let db = fluent.db()
        guard let sugg = try await TagSuggestion.find(id, on: db) else { throw TaggerError.notFound(id) }
        guard sugg.status == "pending" else { throw TaggerError.alreadyResolved(id) }
        if sugg.kind == TaggerPipeline.regradeKind {
            let added = Self.items(of: sugg).filter { $0.kind == .add && $0.applied && $0.reason == TaggerPipeline.addedOnRegrade }.map(\.slug)
            try await movies.removeAutoTags(jellyfinId: sugg.jellyfinId, tagSlugs: added)
        } else if sugg.kind != "removal" {
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
