import Foundation
import FluentKit
import FluentSQLiteDriver
import Hummingbird

// MARK: - Movie Model (slim FK stub to Jellyfin)
final class Movie: Model, @unchecked Sendable {
    static let schema = "movies"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "jellyfin_id")
    var jellyfinId: String

    @OptionalField(key: "last_seen_at")
    var lastSeenAt: Date?

    /// Latest `decisions` row for this film, set by the tagger.
    @OptionalField(key: "current_decision_id")
    var currentDecisionId: UUID?

    @Siblings(through: MovieTag.self, from: \.$movie, to: \.$tag)
    var tags: [Tag]

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, jellyfinId: String, lastSeenAt: Date? = nil) {
        self.id = id
        self.jellyfinId = jellyfinId
        self.lastSeenAt = lastSeenAt
    }
}

// MARK: - Tag Model
final class Tag: Model, @unchecked Sendable {
    static let schema = "tags"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "slug")
    var slug: String

    @Field(key: "title")
    var title: String

    @Field(key: "description")
    var description: String

    @Field(key: "usage_count")
    var usageCount: Int

    @Siblings(through: MovieTag.self, from: \.$tag, to: \.$movie)
    var movies: [Movie]

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        slug: String,
        title: String,
        description: String,
        usageCount: Int = 0
    ) {
        self.id = id
        self.slug = slug
        self.title = title
        self.description = description
        self.usageCount = usageCount
    }
}

// MARK: - Movie-Tag Pivot
final class MovieTag: Model, @unchecked Sendable {
    static let schema = "movie_tags"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "movie_id")
    var movie: Movie

    @Parent(key: "tag_id")
    var tag: Tag

    /// Legacy flag, kept for one release; `labelSource` is the source of truth.
    @Field(key: "added_by_auto_tag")
    var addedByAutoTag: Bool

    /// `seed`, `auto` or `user`. Human-sourced rows are never auto-removed and are the only
    /// ones the eval and calibration treat as ground truth.
    @Field(key: "label_source")
    var labelSource: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        movieId: Movie.IDValue,
        tagId: Tag.IDValue,
        labelSource: LabelSource
    ) {
        self.id = id
        self.$movie.id = movieId
        self.$tag.id = tagId
        self.labelSource = labelSource.rawValue
        self.addedByAutoTag = (labelSource == .auto)
    }

    var source: LabelSource { LabelSource(rawValue: labelSource) ?? .auto }
}

// MARK: - Tag Suggestion Model (auto-tag queue + per-tag refinement proposals)
final class TagSuggestion: Model, @unchecked Sendable {
    static let schema = "tag_suggestions"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "jellyfin_id")
    var jellyfinId: String

    @Field(key: "suggested_tags")
    var suggestedTags: [String]

    @Field(key: "confidence")
    var confidence: Double

    @OptionalField(key: "reasoning")
    var reasoning: String?

    @Field(key: "status")
    var status: String  // "pending" | "approved" | "rejected" | "superseded"

    /// "additive" — row proposes adding the tags in `suggestedTags` (the standard auto-tag flow).
    /// "removal"  — row proposes dropping `removalTagSlug`, surfaced by the per-tag refine pass.
    @Field(key: "kind")
    var kind: String

    @OptionalField(key: "removal_tag_slug")
    var removalTagSlug: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @OptionalField(key: "resolved_at")
    var resolvedAt: Date?

    /// `auto` when the tagger auto-approved the row at creation, `user` when a human resolved it.
    @OptionalField(key: "resolved_by")
    var resolvedBy: String?

    /// The `decisions` row this suggestion came from.
    @OptionalField(key: "decision_id")
    var decisionId: UUID?

    /// `[{ slug, probability, evidence, kind: add|remove }]` for the review UI.
    @OptionalField(key: "items_json")
    var itemsJson: String?

    init() {}

    init(
        id: UUID? = nil,
        jellyfinId: String,
        suggestedTags: [String],
        confidence: Double,
        reasoning: String?,
        status: String = "pending",
        kind: String = "additive",
        removalTagSlug: String? = nil
    ) {
        self.id = id
        self.jellyfinId = jellyfinId
        self.suggestedTags = suggestedTags
        self.confidence = confidence
        self.reasoning = reasoning
        self.status = status
        self.kind = kind
        self.removalTagSlug = removalTagSlug
    }
}

// MARK: - Client DTOs (ID-only)
struct ClientTagEntry: Codable, Sendable {
    let jellyfinId: String
    let tags: [String]
    let needsReview: Bool
}

struct ClientTagsListResponse: Codable, Sendable {
    let items: [ClientTagEntry]
}

struct ClientMoodBlock: Codable, Sendable {
    let slug: String
    let title: String
    let jellyfinIds: [String]
}

struct ClientMoodMoviesResponse: Codable, Sendable {
    let slug: String
    let jellyfinIds: [String]
}

struct ClientHomePayload: Codable, Sendable {
    let randomMood: ClientMoodBlock?
    let featuredMood: ClientMoodBlock?
}

// MARK: - Tag suggestion response DTOs
struct TagSuggestionResponse: Codable, Sendable {
    let id: UUID?
    let jellyfinId: String
    let suggestedTags: [String]
    let confidence: Double
    let reasoning: String?
    let status: String
    let kind: String
    let removalTagSlug: String?
    let createdAt: Date?
    let resolvedAt: Date?
    let resolvedBy: String?
    let decisionId: UUID?
    /// Per-mood detail from the decision: applied and proposed moods with probability and evidence.
    let items: [SuggestionItem]?

    init(_ s: TagSuggestion) {
        self.id = s.id
        self.jellyfinId = s.jellyfinId
        self.suggestedTags = s.suggestedTags
        self.confidence = s.confidence
        self.reasoning = s.reasoning
        self.status = s.status
        self.kind = s.kind
        self.removalTagSlug = s.removalTagSlug
        self.createdAt = s.createdAt
        self.resolvedAt = s.resolvedAt
        self.resolvedBy = s.resolvedBy
        self.decisionId = s.decisionId
        self.items = s.itemsJson.flatMap { try? JSONDecoder().decode([SuggestionItem].self, from: Data($0.utf8)) }
    }
}

struct SuggestionListResponse: Codable, Sendable {
    let items: [TagSuggestionResponse]
}

// MARK: - Backfill DTO
struct BackfillStatus: Codable, Sendable {
    let running: Bool
    let total: Int
    let processed: Int
    let startedAt: Date?
    let cancelled: Bool?
}

// MARK: - OMDb DTOs
struct OmdbCacheEntry: Codable, Sendable {
    let imdbId: String
    let ratings: [OmdbRating]
    /// OMDb's `Awards` summary string, for example "Won 4 Oscars. 309 wins & 271 nominations total".
    let awards: String?
    let fetchedAt: Date
}

struct OmdbRating: Codable, Sendable { let Source: String; let Value: String }

struct SuccessResponse: Codable, Sendable { let success: Bool }

// MARK: - Request DTOs
struct UpdateMovieTagsRequest: Codable, Sendable {
    let tagSlugs: [String]
    let replaceAll: Bool

    func validate() throws {
        guard tagSlugs.count <= 5 else {
            throw ValidationError("Maximum 5 tags allowed per movie")
        }
        let uniqueTags = Set(tagSlugs)
        guard uniqueTags.count == tagSlugs.count else {
            throw ValidationError("Duplicate tags are not allowed")
        }
    }
}

struct ExportMovieTags: Codable, Sendable {
    let tags: [String]
}

struct ValidationError: Error, CustomStringConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var description: String { message }
}
