import Foundation
import Logging

final class NocturneConfiguration: @unchecked Sendable {
    // Server Settings
    var host: String = "0.0.0.0"
    var port: Int = 8001

    // Jellyfin Connection
    var jellyfinUrl: String = "http://192.168.0.111:8097"
    var jellyfinApiKey: String = ""
    var jellyfinUserId: String = ""

    // Database
    var databasePath: String = "nocturne.sqlite"

    // BYOK - Bring Your Own Key (Optional)
    var anthropicApiKey: String? = nil
    var omdbApiKey: String? = nil

    // Poster cache (on-disk LRU, proxies Jellyfin images)
    var posterCacheDir: String = "/app/data/cache/posters"
    var posterCacheMaxBytes: Int64 = 1_073_741_824  // 1 GiB

    // Jellyfin auto-discovery (UDP broadcast on :7359)
    var jellyfinDiscoveryTimeoutMs: Int = 2000

    // Auto-tagging settings
    var enableAutoTagging: Bool = false
    var maxAutoTags: Int = 5
    // The 36 buckets and the manual guide live in Resources/taxonomy.json and Resources/guide.md
    // (loaded in init). taxonomyVersion is stamped on every decision.
    var taxonomyVersion: Int = 0
    var moodBuckets: [String: MoodBucket] = [:]
    var autoTaggingPrompt: String = ""

    init() {
        do {
            let taxonomy = try Taxonomy.load()
            self.taxonomyVersion = taxonomy.version
            self.moodBuckets = taxonomy.buckets
            self.autoTaggingPrompt = try Guide.loadManual()
        } catch {
            // The server cannot tag without its taxonomy; fail at boot with the reason, not at the first film.
            fatalError("Nocturne resources missing or malformed: \(error)")
        }
        if let path = ProcessInfo.processInfo.environment["NOCTURNE_DATABASE_PATH"], !path.isEmpty {
            self.databasePath = path
        } else {
            self.databasePath = "/app/data/nocturne.sqlite"
        }
        // Poster cache lives alongside the database so they share volume lifecycle.
        let dbDir = (self.databasePath as NSString).deletingLastPathComponent
        self.posterCacheDir = (dbDir as NSString).appendingPathComponent("cache/posters")
        if let override = ProcessInfo.processInfo.environment["NOCTURNE_POSTER_CACHE_DIR"], !override.isEmpty {
            self.posterCacheDir = override
        }
        if let raw = ProcessInfo.processInfo.environment["NOCTURNE_POSTER_CACHE_MAX_BYTES"],
           let bytes = Int64(raw), bytes > 0 {
            self.posterCacheMaxBytes = bytes
        }
    }
}

struct MoodBucket: Codable, Sendable {
    let title: String
    let description: String        // the residue in one or two sentences; shown in the web UI and seeded into `tags`
    let tags: [String]?            // v1 keywords; v2 buckets carry `cues` instead
    let anchorsFit: [String]?      // films that fit, each with the reason (reader-facing)
    let anchorsMiss: [String]?     // close-but-no films, each with the redirect (reader-facing)
    let minConfidence: Double?     // per-tag confidence floor; nil falls back to the policy default
    let qualifies: [String]?       // v2: conditions the film text has to meet, checked one by one (reader-facing)
    let cues: [String]?            // v2: phrases that tend to appear in the text block when the bucket fits
}

extension MoodBucket {
    init(title: String, description: String) {
        self.init(
            title: title, description: description,
            tags: nil, anchorsFit: nil, anchorsMiss: nil, minConfidence: nil, qualifies: nil, cues: nil)
    }

    init(title: String, description: String, tags: [String]?) {
        self.init(
            title: title, description: description,
            tags: tags, anchorsFit: nil, anchorsMiss: nil, minConfidence: nil, qualifies: nil, cues: nil)
    }
}

struct MoodBucketsResponse: Codable, Sendable {
    let moods: [String: MoodBucket]
}
