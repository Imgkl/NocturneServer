import Foundation
import FluentKit
import FluentSQL

struct CreateMovies: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("movies")
            .id()
            .field("jellyfin_id", .string, .required)
            .field("last_seen_at", .datetime)
            .field("created_at", .datetime)
            .unique(on: "jellyfin_id")
            .create()
    }
    func revert(on database: Database) async throws {
        try await database.schema("movies").delete()
    }
}

struct CreateTags: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("tags")
            .id()
            .field("slug", .string, .required)
            .field("title", .string, .required)
            .field("description", .string, .required)
            .field("usage_count", .int, .required)
            .field("created_at", .datetime)
            .unique(on: "slug")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("tags").delete()
    }
}

struct CreateMovieTags: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("movie_tags")
            .id()
            .field("movie_id", .uuid, .required, .references("movies", "id", onDelete: .cascade))
            .field("tag_id", .uuid, .required, .references("tags", "id", onDelete: .cascade))
            .field("added_by_auto_tag", .bool, .required)
            .field("created_at", .datetime)
            .unique(on: "movie_id", "tag_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("movie_tags").delete()
    }
}

struct SeedMoodTags: AsyncMigration {
    func prepare(on database: Database) async throws {
        let moodBuckets: [String: MoodBucket] = [
            "dialogue-driven": MoodBucket(
                title: "Dialogue-Driven",
                description: "Conversations carry the drama; words hit harder than action."
            ),
            "vibe-is-the-plot": MoodBucket(
                title: "Vibe Is the Plot",
                description: "Atmosphere leads; feeling and tone do the storytelling."
            ),
            "existential-core": MoodBucket(
                title: "Existential Core",
                description: "Meditations on purpose, mortality, identity, and meaning."
            ),
            "crime-grit-style": MoodBucket(
                title: "Crime, Grit & Style",
                description: "Stylish crime worlds where every choice has consequence."
            ),
            "men-with-vibes": MoodBucket(
                title: "Men With Vibes (and Guns)",
                description: "Stoic cool, coiled menace, and charisma that fills the frame."
            ),
            "brainmelt-zone": MoodBucket(
                title: "Brainmelt Zone",
                description: "Reality tilts—memory, identity, and truth become puzzles."
            ),
            "the-twist-is-the-plot": MoodBucket(
                title: "The Twist Is the Plot",
                description: "Engineered reveals that reframe everything you saw."
            ),
            "slow-burn-sharp-blade": MoodBucket(
                title: "Slow Burn, Sharp Blade",
                description: "Patient builds that pay off with surgical intensity."
            ),
            "one-room-pressure-cooker": MoodBucket(
                title: "One-Room Pressure Cooker",
                description: "Minimal locations; maximal tension and performance."
            ),
            "psychological-pressure-cooker": MoodBucket(
                title: "Psychological Pressure-Cooker",
                description: "Claustrophobic paranoia and minds fraying under stakes."
            ),
            "time-twists": MoodBucket(
                title: "Time Twists",
                description: "Loops, leaps, and fractured timelines drive the drama."
            ),
            "visual-worship": MoodBucket(
                title: "Visual Worship",
                description: "Every frame composed like a poster; image-first cinema."
            ),
            "obsidian-noir": MoodBucket(
                title: "Obsidian Noir",
                description: "Inky shadows, moral fog, and sleek modern-noir aesthetics."
            ),
            "rain-neon-aesthetic": MoodBucket(
                title: "Rain & Neon Aesthetic",
                description: "Wet streets, neon glow, synthy urban melancholy."
            ),
            "rainy-day-rewinds": MoodBucket(
                title: "Rainy Day Rewinds",
                description: "Comfort watches with endless rewatch value and warmth."
            ),
            "feel-good-romance": MoodBucket(
                title: "Feel-Good Romance",
                description: "Tender, uplifting love stories that leave a glow."
            ),
            "coming-of-age": MoodBucket(
                title: "Coming of Age",
                description: "Awkward growth, firsts, and the sting of becoming."
            ),
            "late-night-mind-rattle": MoodBucket(
                title: "Late-Night Mind Rattle",
                description: "Haunting strangeness that echoes at 1:47 a.m."
            ),
            "uncanny-vibes": MoodBucket(
                title: "Uncanny Vibes",
                description: "Slightly off reality—dreamy, eerie, or liminal moods."
            ),
            "horror-and-unease": MoodBucket(
                title: "Horror & Unease",
                description: "Dread-forward films that haunt more than they jump-scare."
            ),
            "wtf-did-i-watch": MoodBucket(
                title: "WTF Did I Watch",
                description: "Transgressive or absurd—disturbing yet unforgettable."
            ),
            "film-school-shelf": MoodBucket(
                title: "Film School Shelf",
                description: "Canonical essentials that define film literacy."
            ),
            "modern-masterpieces": MoodBucket(
                title: "Modern Masterpieces",
                description: "2000s+ pinnacles acclaimed for craft and resonance."
            ),
            "regional-gems": MoodBucket(
                title: "Regional Gems",
                description: "Critically recognized or culturally significant Indian cinema (Tamil, Hindi, Malayalam, Bengali, etc.) — award winners, festival standouts, or genre landmarks. Not every film from the region."
            ),
            "underseen-treasures": MoodBucket(
                title: "Underseen Treasures",
                description: "Overlooked gems worth championing and discovery."
            ),
            "heist-energy": MoodBucket(
                title: "Heist Energy",
                description: "Clever planning, betrayals, and the thrill of the score."
            ),
            "cat-and-mouse": MoodBucket(
                title: "Cat and Mouse",
                description: "Predator and prey in a strategic, escalating duel."
            ),
            "antihero-study": MoodBucket(
                title: "Antihero Study",
                description: "Magnetic, flawed leads bending morality to breaking."
            ),
            "ensemble-mosaic": MoodBucket(
                title: "Ensemble Mosaic",
                description: "Interlocking characters and perspectives in harmony."
            ),
            "quiet-epics": MoodBucket(
                title: "Quiet Epics",
                description: "Large-scale stakes told with restraint and intimacy."
            ),
            "bittersweet-aftermath": MoodBucket(
                title: "Bittersweet Aftermath",
                description: "Endings that ache softly—loss braided with grace."
            ),
            "based-on-vibes-true-story": MoodBucket(
                title: "Based on Vibes (True Story)",
                description: "Fact-rooted stories elevated by tone and mood."
            ),
            "cult-chaos": MoodBucket(
                title: "Cult Chaos",
                description: "Bizarre, confrontational favorites that inspire obsession."
            ),
            "experimental-cinema": MoodBucket(
                title: "Experimental Cinema",
                description: "Form-forward films that break rules to find new rhythms."
            )
        ]

        for (slug, bucket) in moodBuckets.sorted(by: { $0.key < $1.key }) {
            let tag = Tag(slug: slug, title: bucket.title, description: bucket.description, usageCount: 0)
            try await tag.save(on: database)
        }
    }

    func revert(on database: Database) async throws {
        try await Tag.query(on: database).delete()
    }
}

struct UpdateRegionalGemsDescription: AsyncMigration {
    func prepare(on database: Database) async throws {
        let newDescription = "Critically recognized or culturally significant Indian cinema (Tamil, Hindi, Malayalam, Bengali, etc.) — award winners, festival standouts, or genre landmarks. Not every film from the region."
        if let tag = try await Tag.query(on: database)
            .filter(\.$slug == "regional-gems")
            .first()
        {
            tag.description = newDescription
            try await tag.save(on: database)
        }
    }

    func revert(on database: Database) async throws {
        let oldDescription = "Standouts from Tamil, Hindi, and wider Indian cinema."
        if let tag = try await Tag.query(on: database)
            .filter(\.$slug == "regional-gems")
            .first()
        {
            tag.description = oldDescription
            try await tag.save(on: database)
        }
    }
}

struct CreateTagSuggestions: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("tag_suggestions")
            .id()
            .field("jellyfin_id", .string, .required)
            .field("suggested_tags", .array(of: .string), .required)
            .field("confidence", .double, .required)
            .field("reasoning", .string)
            .field("status", .string, .required)
            .field("created_at", .datetime)
            .field("resolved_at", .datetime)
            .create()
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw("CREATE INDEX IF NOT EXISTS tag_suggestions_jellyfin_id_idx ON tag_suggestions(jellyfin_id)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS tag_suggestions_status_idx ON tag_suggestions(status)").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("tag_suggestions").delete()
    }
}
