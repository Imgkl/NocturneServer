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

    @Field(key: "added_by_auto_tag")
    var addedByAutoTag: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        movieId: Movie.IDValue,
        tagId: Tag.IDValue,
        addedByAutoTag: Bool = false
    ) {
        self.id = id
        self.$movie.id = movieId
        self.$tag.id = tagId
        self.addedByAutoTag = addedByAutoTag
    }
}

// MARK: - Tag Suggestion Model (auto-tag queue)
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
    var status: String  // "pending" | "approved" | "rejected"

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @OptionalField(key: "resolved_at")
    var resolvedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        jellyfinId: String,
        suggestedTags: [String],
        confidence: Double,
        reasoning: String?,
        status: String = "pending"
    ) {
        self.id = id
        self.jellyfinId = jellyfinId
        self.suggestedTags = suggestedTags
        self.confidence = confidence
        self.reasoning = reasoning
        self.status = status
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
    let createdAt: Date?
    let resolvedAt: Date?

    init(_ s: TagSuggestion) {
        self.id = s.id
        self.jellyfinId = s.jellyfinId
        self.suggestedTags = s.suggestedTags
        self.confidence = s.confidence
        self.reasoning = s.reasoning
        self.status = s.status
        self.createdAt = s.createdAt
        self.resolvedAt = s.resolvedAt
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

struct AutoTagResponse: Codable, Sendable {
    struct TagWithConfidence: Codable, Sendable {
        let slug: String
        let confidence: Double
        let evidence: String?
    }
    let residue: String?
    let tags: [TagWithConfidence]
    let reasoning: String?

    var suggestions: [String] { tags.map(\.slug) }
    var confidence: Double { tags.map(\.confidence).min() ?? 0 }
    var overallConfidence: Double { confidence }

    enum CodingKeys: String, CodingKey {
        case residue, tags, reasoning, suggestions, confidence
    }

    init(residue: String?, tags: [TagWithConfidence], reasoning: String? = nil) {
        self.residue = residue
        self.tags = tags
        self.reasoning = reasoning
    }

    /// Lenient decoder: accepts the new `{residue, tags: [{slug, confidence, evidence}]}` shape
    /// or the legacy `{suggestions: [slug], confidence: 0.85}` shape so old cached responses /
    /// LLM schema drift don't silently drop entire movies.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.residue = try c.decodeIfPresent(String.self, forKey: .residue)
        self.reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning)
        if let newTags = try? c.decode([TagWithConfidence].self, forKey: .tags) {
            self.tags = newTags
        } else if let oldSlugs = try? c.decode([String].self, forKey: .suggestions) {
            let oldConf = (try? c.decode(Double.self, forKey: .confidence)) ?? 0.70
            self.tags = oldSlugs.map {
                TagWithConfidence(slug: $0, confidence: oldConf, evidence: nil)
            }
        } else {
            self.tags = []
        }
    }

    /// Encode writes the canonical new-schema shape so refine prompts round-trip cleanly.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(residue, forKey: .residue)
        try c.encode(tags, forKey: .tags)
        try c.encodeIfPresent(reasoning, forKey: .reasoning)
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
