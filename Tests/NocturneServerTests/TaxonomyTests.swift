import FluentKit
import Foundation
import Testing

@testable import NocturneServer

@Suite struct TaxonomyTests {

    @Test func loadsAllThirtySixBucketsWithTheirFields() throws {
        let taxonomy = try Taxonomy.load()
        #expect(taxonomy.version == 2)
        #expect(taxonomy.buckets.count == 36)
        let haha = try #require(taxonomy.buckets["ha-ha-ha"])
        #expect(haha.title == "Ha Ha Ha")
        #expect(haha.minConfidence == 0.8)
        #expect(haha.cues?.contains("comedy") == true)
        #expect(haha.tags == nil)
        #expect(haha.qualifies?.count == 3)
        #expect(haha.anchorsFit?.count == 6)
        #expect(haha.anchorsMiss?.first?.contains("Zindagi Na Milegi Dobara") == true)
        let twists = try #require(taxonomy.buckets["time-twists"])
        #expect(twists.minConfidence == 0.78)
        #expect(twists.anchorsFit?.count == 8)
        #expect(taxonomy.buckets["emotional-gut-punch"] != nil)
        #expect(taxonomy.buckets["regional-gems"]?.description.contains("Indian cinema") == true)
        #expect(taxonomy.buckets["regional-gems"]?.minConfidence == 0.85)
    }

    @Test func everyBucketCarriesTheV2Fields() throws {
        let taxonomy = try Taxonomy.load()
        let canon: Set<String> = ["film-school-shelf", "modern-masterpieces", "regional-gems", "cult-chaos", "underseen-treasures", "experimental-cinema"]
        let mechanics: Set<String> = ["time-twists", "heist-energy", "one-room-pressure-cooker", "the-twist-is-the-plot", "ensemble-mosaic"]
        for (slug, bucket) in taxonomy.buckets {
            #expect((bucket.qualifies?.count ?? 0) >= 3, "\(slug) qualifies")
            #expect((bucket.cues?.count ?? 0) >= 5, "\(slug) cues")
            #expect((bucket.anchorsFit?.count ?? 0) >= 4, "\(slug) fits")
            #expect((bucket.anchorsMiss?.count ?? 0) >= 2, "\(slug) misses")
            #expect(bucket.tags == nil, "\(slug) still carries v1 keywords")
            let expectedFloor = canon.contains(slug) ? 0.85 : mechanics.contains(slug) ? 0.78 : 0.8
            #expect(bucket.minConfidence == expectedFloor, "\(slug) floor")
            // The seed keeps the first sentence of the description as the tag's short description.
            let first = bucket.description.components(separatedBy: ". ").first ?? ""
            #expect(first.count >= 15, "\(slug) first sentence")
            #expect(!bucket.description.contains("\u{2014}") && !bucket.description.contains("\u{2013}"), "\(slug) dash")
        }
    }

    @Test func configurationIsLoadedFromResources() {
        let config = NocturneConfiguration()
        #expect(config.taxonomyVersion == 2)
        #expect(config.moodBuckets.count == 36)
        #expect(config.autoTaggingPrompt.hasPrefix("You are a meticulous film taxonomy expert."))
        #expect(config.autoTaggingPrompt.contains("Rule 0: Residue first"))
        #expect(config.autoTaggingPrompt.contains("Rule 6: Confidence means something"))
        #expect(!config.autoTaggingPrompt.contains("Min confidence"))
        #expect(!config.autoTaggingPrompt.contains("\u{2014}"))
    }

    @Test func guideLoads() throws {
        let guide = try Guide.loadManual()
        #expect(guide.contains("Few-shot calibration examples"))
        #expect(guide.contains("Apply Rules 1 to 7"))
    }

    @Test func malformedResourcesFailLoudly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("taxonomy-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let bad = dir.appendingPathComponent("bad.json")
        try Data("{\"version\": 1, \"buckets\": {}}".utf8).write(to: bad)
        #expect(throws: ResourceError.self) { _ = try Taxonomy.load(from: bad) }

        try Data("{\"version\": 0, \"buckets\": {\"x\": {\"title\": \"X\", \"description\": \"d\"}}}".utf8).write(to: bad)
        #expect(throws: ResourceError.self) { _ = try Taxonomy.load(from: bad) }

        try Data("{\"version\": 1, \"buckets\": {\"Bad Slug\": {\"title\": \"X\", \"description\": \"d\"}}}".utf8).write(to: bad)
        #expect(throws: ResourceError.self) { _ = try Taxonomy.load(from: bad) }

        try Data("{\"version\": 1, \"buckets\": {\"ok\": {\"title\": \"X\", \"description\": \"d\", \"minConfidence\": 1.5}}}".utf8).write(to: bad)
        #expect(throws: ResourceError.self) { _ = try Taxonomy.load(from: bad) }

        try Data("not json".utf8).write(to: bad)
        #expect(throws: ResourceError.self) { _ = try Taxonomy.load(from: bad) }

        let good = dir.appendingPathComponent("good.json")
        try Data("{\"version\": 2, \"buckets\": {\"ok\": {\"title\": \"X\", \"description\": \"d\"}}}".utf8).write(to: good)
        let loaded = try Taxonomy.load(from: good)
        #expect(loaded.version == 2)
        #expect(loaded.buckets["ok"]?.minConfidence == nil)

        let emptyGuide = dir.appendingPathComponent("guide.md")
        try Data("  \n".utf8).write(to: emptyGuide)
        #expect(throws: ResourceError.self) { _ = try Guide.load(from: emptyGuide) }
    }

    @Test func seedFillsTheMissingMoodTags() async throws {
        try await withTestFluent { fluent in
            let slugs = Set(try await Tag.query(on: fluent.db()).all().map(\.slug))
            #expect(slugs.count == 36)
            #expect(slugs.contains("ha-ha-ha"))
            #expect(slugs.contains("emotional-gut-punch"))
            let haha = try #require(try await Tag.query(on: fluent.db()).filter(\.$slug == "ha-ha-ha").first())
            #expect(haha.title == "Ha Ha Ha")
            #expect(haha.description.hasPrefix("You leave having laughed, a lot."))
        }
    }
}
