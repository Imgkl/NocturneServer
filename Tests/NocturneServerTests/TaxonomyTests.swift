import FluentKit
import Foundation
import Testing

@testable import NocturneServer

@Suite struct TaxonomyTests {

    @Test func loadsAllThirtySixBucketsWithTheirFields() throws {
        let taxonomy = try Taxonomy.load()
        #expect(taxonomy.version == 1)
        #expect(taxonomy.buckets.count == 36)
        let haha = try #require(taxonomy.buckets["ha-ha-ha"])
        #expect(haha.title == "Ha Ha Ha")
        #expect(haha.minConfidence == 0.82)
        #expect(haha.tags?.contains("comedy") == true)
        #expect(haha.anchorsFit?.count == 5)
        #expect(haha.anchorsMiss?.first?.contains("Little Miss Sunshine") == true)
        let twists = try #require(taxonomy.buckets["time-twists"])
        #expect(twists.minConfidence == 0.65)
        #expect(twists.anchorsFit?.count == 12)
        #expect(taxonomy.buckets["emotional-gut-punch"] != nil)
        #expect(taxonomy.buckets["regional-gems"]?.description.contains("Indian-cinema") == true)
    }

    @Test func configurationIsLoadedFromResources() {
        let config = NocturneConfiguration()
        #expect(config.taxonomyVersion == 1)
        #expect(config.moodBuckets.count == 36)
        #expect(config.autoTaggingPrompt.hasPrefix("You are a meticulous film taxonomy expert."))
        #expect(config.autoTaggingPrompt.contains("Rule 0 — Residue-first"))
        #expect(!config.autoTaggingPrompt.contains("Min confidence"))
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
            #expect(haha.description.hasPrefix("You leave having LAUGHED."))
        }
    }
}
