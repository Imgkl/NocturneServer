import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import Testing

@testable import NocturneServer

@Suite struct AwardsResolverTests {

    private func make(_ fluent: Fluent, _ transport: FakeTransport, cap: Int = 900) async throws -> AwardsResolver {
        let outbound = OutboundClient(transport: transport, fluent: fluent, logger: Logger(label: "test"), sleeper: { _ in }, jitter: { 0 })
        let settings = SettingsStore(db: fluent.db(), logger: Logger(label: "test"))
        try await settings.ensureTable()
        let cache = OmdbCacheStore(db: fluent.db(), logger: Logger(label: "test"))
        try await cache.ensureTable()
        return AwardsResolver(
            outbound: outbound, fluent: fluent, limiter: RateLimiter(perSecond: 1_000),
            userAgent: "NocturneServer-tests/0.1 (test)", omdb: OmdbClient(outbound: outbound),
            omdbCache: cache, settings: settings, dailyOmdbCap: cap, logger: Logger(label: "test"))
    }

    private func labelsBody(_ qids: [String]) -> String {
        let entities = qids.map { "\"\($0)\":{\"id\":\"\($0)\",\"labels\":{\"en\":{\"language\":\"en\",\"value\":\"Label \($0)\"}}}" }
        return "{\"entities\":{\(entities.joined(separator: ","))},\"success\":1}"
    }

    @Test func labelsAreBatchedByFiftyAndCached() async throws {
        try await withTestFluent { fluent in
            let qids = (1...120).map { "Q\($0)" }
            let sorted = qids.sorted()
            let transport = FakeTransport([
                .response(status: 200, body: labelsBody(Array(sorted[0..<50]))),
                .response(status: 200, body: labelsBody(Array(sorted[50..<100]))),
                .response(status: 200, body: labelsBody(Array(sorted[100..<120]))),
            ])
            let resolver = try await make(fluent, transport)

            let first = try await resolver.labels(for: qids)
            #expect(first.count == 120)
            #expect(first["Q7"] == "Label Q7")
            #expect(transport.requestCount == 3)
            #expect(transport.requests.allSatisfy { $0.url.contains("props=labels") && $0.url.contains("languages=en") })
            #expect(try await WikidataLabel.query(on: fluent.db()).count() == 120)

            let second = try await resolver.labels(for: qids.shuffled())
            #expect(second == first)
            #expect(transport.requestCount == 3)
        }
    }

    @Test func parasiteAwardsAreNamedAndOrdered() async throws {
        try await withTestFluent { fluent in
            let entity = try JSONDecoder().decode(WikidataResolver.EntitiesResponse.self, from: try fixtureData("wikidata/entity-Q61448040.json"))
            let resolution = WikidataResolver.reduce(qid: "Q61448040", entity: try #require(entity.entities?["Q61448040"]))
            let transport = FakeTransport([.response(status: 200, body: String(decoding: try fixtureData("wikidata/labels-batch.json"), as: UTF8.self))])
            let resolver = try await make(fluent, transport)

            let awards = try await resolver.awards(from: resolution)
            let won = awards.filter { $0.kind == .won }
            let nominated = awards.filter { $0.kind == .nominated }
            #expect(won.count == 14)
            #expect(nominated.count == 8)
            #expect(awards.prefix(14).allSatisfy { $0.kind == .won })
            #expect(won.contains(Award(name: "Palme d'Or", kind: .won, year: 2019)))
            #expect(won.contains { $0.name == "Academy Award for Best Picture" })
            // Deterministic: a second call gives the same order and makes no new request.
            let again = try await resolver.awards(from: resolution)
            #expect(again == awards)
            #expect(transport.requestCount == 1)
        }
    }

    @Test func omdbPayloadDecoding() throws {
        let heat = try JSONDecoder().decode(OmdbPayload.self, from: try fixtureData("omdb/heat.json"))
        #expect(heat.isOk)
        #expect(heat.awards == "Nominated for 1 BAFTA Award. 12 wins & 15 nominations total")
        #expect(heat.ratings.count == 3)
        let none = try JSONDecoder().decode(OmdbPayload.self, from: try fixtureData("omdb/no-awards.json"))
        #expect(none.awards == nil)
        let na = try JSONDecoder().decode(OmdbPayload.self, from: Data(#"{"Awards":"N/A","Response":"True"}"#.utf8))
        #expect(na.awards == nil)
    }

    @Test func omdbAwardsCacheKeyAndCap() async throws {
        try await withTestFluent { fluent in
            let heatJson = String(decoding: try fixtureData("omdb/heat.json"), as: UTF8.self)
            let transport = FakeTransport([
                .response(status: 200, body: heatJson),
                .response(status: 200, body: #"{"Response":"False","Error":"Incorrect IMDb ID."}"#),
            ])
            let resolver = try await make(fluent, transport)

            // No key configured: nothing is called.
            #expect(await resolver.omdbAwards(imdbId: "tt0113277") == nil)
            #expect(transport.requestCount == 0)

            try await resolver.settings.set(AwardsResolver.omdbKeySetting, "k")
            // Cache miss with a key: one call, stored, returned.
            #expect(await resolver.omdbAwards(imdbId: "tt0113277") == "Nominated for 1 BAFTA Award. 12 wins & 15 nominations total")
            #expect(transport.requestCount == 1)
            let cached = try await resolver.omdbCache.get(imdbId: "tt0113277")
            #expect(cached?.ratings.count == 3)
            #expect(cached?.awards != nil)

            // Cache hit: no call.
            #expect(await resolver.omdbAwards(imdbId: "tt0113277") != nil)
            #expect(transport.requestCount == 1)

            // Unknown id: OMDb says False, nothing stored, nil.
            #expect(await resolver.omdbAwards(imdbId: "tt0000000") == nil)
            #expect(transport.requestCount == 2)
            #expect(try await resolver.omdbCache.get(imdbId: "tt0000000") == nil)

            // Key never appears in metering rows.
            let rows = try await ApiCall.query(on: fluent.db()).filter(\.$provider == "omdb").all()
            #expect(rows.count == 2)
            #expect(rows.allSatisfy { !$0.endpoint.contains("k") || $0.endpoint == "/" })
        }
    }

    @Test func omdbDailyCapStopsCalls() async throws {
        try await withTestFluent { fluent in
            let transport = FakeTransport([.response(status: 200, body: String(decoding: try fixtureData("omdb/heat.json"), as: UTF8.self))])
            let resolver = try await make(fluent, transport, cap: 2)
            try await resolver.settings.set(AwardsResolver.omdbKeySetting, "k")
            for _ in 0..<2 {
                try await ApiCall(runId: nil, decisionId: nil, provider: "omdb", endpoint: "/", model: nil, attempt: 1, httpStatus: 200, durationMs: 1, unitsJson: "{}", costUsd: 0).save(on: fluent.db())
            }
            #expect(try await resolver.omdbCallsToday() == 2)
            #expect(await resolver.omdbAwards(imdbId: "tt0113277") == nil)
            #expect(transport.requestCount == 0)
        }
    }
}
