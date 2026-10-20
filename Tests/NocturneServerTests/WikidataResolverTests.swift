import Foundation
import HummingbirdFluent
import Logging
import Testing

@testable import NocturneServer

@Suite struct WikidataResolverTests {

    private func fixture(_ name: String) throws -> String {
        String(decoding: try fixtureData("wikidata/\(name)"), as: UTF8.self)
    }

    private func resolver(_ fluent: Fluent, _ transport: FakeTransport) -> WikidataResolver {
        let outbound = OutboundClient(transport: transport, fluent: fluent, logger: Logger(label: "test"), sleeper: { _ in }, jitter: { 0 })
        return WikidataResolver(outbound: outbound, limiter: RateLimiter(perSecond: 1_000), userAgent: "NocturneServer-tests/0.1 (test)")
    }

    private static let emptySearch = #"{"batchcomplete":"","query":{"searchinfo":{"totalhits":0},"search":[]}}"#
    private static let emptyTitleSearch = #"{"searchinfo":{"search":"x"},"search":[],"success":1}"#

    @Test func resolvesHeatByImdbId() async throws {
        try await withTestFluent { fluent in
            let transport = FakeTransport([
                .response(status: 200, body: try fixture("search-imdb-tt0113277.json")),
                .response(status: 200, body: try fixture("entity-Q42198.json")),
            ])
            let outcome = try await resolver(fluent, transport).resolve(imdbId: "tt0113277", tmdbId: nil, title: "Heat", year: 1995)
            let r = try #require(outcome.resolution)
            #expect(r.qid == "Q42198")
            #expect(r.enwikiTitle == "Heat (1995 film)")
            #expect(r.imdbId == "tt0113277")
            #expect(r.isFilm)
            #expect(r.publicationYears.contains(1995))
            #expect(r.awardsWon.isEmpty)
            #expect(transport.requestCount == 2)
            #expect(transport.requests.first?.headers["user-agent"]?.contains("NocturneServer") == true)
            #expect(transport.requests.first?.url.contains("haswbstatement") == true)
        }
    }

    @Test func parasiteCarriesStructuredAwardsAndOtherWikis() async throws {
        try await withTestFluent { fluent in
            let transport = FakeTransport([
                .response(status: 200, body: try fixture("search-imdb-tt6751668.json")),
                .response(status: 200, body: try fixture("entity-Q61448040.json")),
            ])
            let outcome = try await resolver(fluent, transport).resolve(imdbId: "tt6751668", tmdbId: nil, title: "Parasite", year: 2019)
            let r = try #require(outcome.resolution)
            #expect(r.qid == "Q61448040")
            #expect(r.tmdbId == "496243")
            #expect(r.awardsWon.count == 14)
            #expect(r.awardsNominated.count == 8)
            #expect(r.awardsWon.contains(AwardClaim(qid: "Q179808", year: 2019)))
            #expect(r.sitelinks["tawiki"] != nil)
            #expect(r.sitelinks["mlwiki"] != nil)
            #expect(r.instanceOf == ["Q11424"])
        }
    }

    @Test func titleSearchPicksTheFilmNotTheSoundtrack() async throws {
        try await withTestFluent { fluent in
            // Search order reversed on purpose: the album comes first and must be skipped by P31.
            let albumFirst = #"{"search":[{"id":"Q123703039","label":"Kadaisi vivasayi","description":"2022 soundtrack album"},{"id":"Q60738204","label":"Kadaisi Vivasayi","description":"film directed by M. Manikandan"}],"success":1}"#
            let albumEntity = #"{"entities":{"Q123703039":{"type":"item","id":"Q123703039","claims":{"P31":[{"mainsnak":{"snaktype":"value","property":"P31","datavalue":{"value":{"entity-type":"item","id":"Q482994"},"type":"wikibase-entityid"}}}]},"sitelinks":{}}}}"#
            let transport = FakeTransport([
                .response(status: 200, body: albumFirst),
                .response(status: 200, body: albumEntity),
                .response(status: 200, body: try fixture("entity-Q60738204.json")),
            ])
            let outcome = try await resolver(fluent, transport).resolve(imdbId: nil, tmdbId: nil, title: "Kadaisi Vivasayi", year: 2022)
            let r = try #require(outcome.resolution)
            #expect(r.qid == "Q60738204")
            #expect(r.imdbId == "tt10300570")
            #expect(r.enwikiTitle == "Kadaisi Vivasayi")
            #expect(r.sitelinks["tawiki"] == "கடைசி விவசாயி")
            #expect(transport.requestCount == 3)
        }
    }

    @Test func garbageImdbIdFallsThroughToTitleSearch() async throws {
        try await withTestFluent { fluent in
            // Wikidata really does return a hit for tt0000000 (a 2026 film carrying it as a placeholder).
            // The entity's year does not match 1995, so the resolver must not accept it.
            let placeholderEntity = #"{"entities":{"Q137599605":{"type":"item","id":"Q137599605","claims":{"P345":[{"mainsnak":{"snaktype":"value","property":"P345","datavalue":{"value":"tt0000000","type":"string"}}}],"P31":[{"mainsnak":{"snaktype":"value","property":"P31","datavalue":{"value":{"entity-type":"item","id":"Q11424"},"type":"wikibase-entityid"}}}],"P577":[{"mainsnak":{"snaktype":"value","property":"P577","datavalue":{"value":{"time":"+2026-01-01T00:00:00Z","precision":11},"type":"time"}}}]},"sitelinks":{}}}}"#
            let heatTitleSearch = #"{"search":[{"id":"Q42198","label":"Heat","description":"1995 film by Michael Mann"}],"success":1}"#
            let transport = FakeTransport([
                .response(status: 200, body: try fixture("search-imdb-tt0000000.json")),
                .response(status: 200, body: placeholderEntity),
                .response(status: 200, body: heatTitleSearch),
                .response(status: 200, body: try fixture("entity-Q42198.json")),
            ])
            let outcome = try await resolver(fluent, transport).resolve(imdbId: "tt0000000", tmdbId: nil, title: "Heat", year: 1995)
            #expect(outcome.resolution?.qid == "Q42198")
            #expect(transport.requestCount == 4)
        }
    }

    @Test func nothingFoundIsUnresolvedNotAnError() async throws {
        try await withTestFluent { fluent in
            let transport = FakeTransport([
                .response(status: 200, body: Self.emptySearch),
                .response(status: 200, body: Self.emptySearch),
                .response(status: 200, body: Self.emptyTitleSearch),
            ])
            let outcome = try await resolver(fluent, transport).resolve(imdbId: "tt9999999", tmdbId: "1", title: "Nope", year: 2001)
            guard case .unresolved(let reason) = outcome else {
                Issue.record("expected unresolved, got \(outcome)")
                return
            }
            #expect(reason.contains("tt9999999"))
            #expect(reason.contains("Nope"))
            #expect(transport.requestCount == 3)
        }
    }

    @Test func malformedImdbIdIsIgnored() async throws {
        try await withTestFluent { fluent in
            let transport = FakeTransport([.response(status: 200, body: Self.emptyTitleSearch)])
            let outcome = try await resolver(fluent, transport).resolve(imdbId: "not-an-id", tmdbId: nil, title: "X", year: nil)
            if case .resolved = outcome { Issue.record("should not resolve") }
            #expect(transport.requestCount == 1)
        }
    }

    @Test func yearParsingHandlesWikidataTimeForms() {
        #expect(WikidataResolver.year(fromWikidataTime: "+2019-05-30T00:00:00Z") == 2019)
        #expect(WikidataResolver.year(fromWikidataTime: "+2019-00-00T00:00:00Z") == 2019)
        #expect(WikidataResolver.year(fromWikidataTime: "-0050-00-00T00:00:00Z") == 50)
        #expect(WikidataResolver.normalizeImdb(" TT0113277 ") == "tt0113277")
        #expect(WikidataResolver.normalizeImdb("949") == nil)
        #expect(WikidataResolver.normalizeImdb("") == nil)
    }
}
