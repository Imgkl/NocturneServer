import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import Testing

@testable import NocturneServer

@Suite struct WikipediaClientTests {

    private func client(_ fluent: Fluent, _ transport: FakeTransport) -> WikipediaClient {
        let outbound = OutboundClient(transport: transport, fluent: fluent, logger: Logger(label: "test"), sleeper: { _ in }, jitter: { 0 })
        return WikipediaClient(outbound: outbound, limiter: RateLimiter(perSecond: 1_000), userAgent: "NocturneServer-tests/0.1 (test)")
    }

    @Test func fetchesEnglishArticleWithProperRequest() async throws {
        try await withTestFluent { fluent in
            let transport = FakeTransport([.response(status: 200, body: String(decoding: try fixtureData("wikipedia/heat-1995-film.json"), as: UTF8.self))])
            let article = try await client(fluent, transport).article(site: "enwiki", title: "Heat (1995 film)")
            #expect(article?.title == "Heat (1995 film)")
            #expect(article?.extract.contains("== Plot ==") == true)

            let request = try #require(transport.requests.first)
            #expect(request.url.hasPrefix("https://en.wikipedia.org/w/api.php?"))
            #expect(request.url.contains("prop=extracts"))
            #expect(request.url.contains("explaintext=1"))
            #expect(request.url.contains("exsectionformat=wiki"))
            #expect(request.url.contains("redirects=1"))
            #expect(request.url.contains("titles=Heat%20(1995%20film)"))
            #expect(request.headers["user-agent"]?.contains("NocturneServer") == true)

            let rows = try await ApiCall.query(on: fluent.db()).all()
            #expect(rows.count == 1)
            #expect(rows.first?.provider == "wikimedia")
            #expect(rows.first?.endpoint == "enwiki/extracts")
        }
    }

    @Test func otherLanguageSiteUsesItsOwnHost() async throws {
        try await withTestFluent { fluent in
            let transport = FakeTransport([.response(status: 200, body: String(decoding: try fixtureData("wikipedia/ta-nayakan.json"), as: UTF8.self))])
            let article = try await client(fluent, transport).article(site: "tawiki", title: "நாயகன் (திரைப்படம்)")
            #expect(article?.site == "tawiki")
            #expect(article?.title == "நாயகன்")  // redirect followed by the API
            #expect(transport.requests.first?.url.hasPrefix("https://ta.wikipedia.org/") == true)
        }
    }

    @Test func missingPageReturnsNil() async throws {
        try await withTestFluent { fluent in
            let transport = FakeTransport([.response(status: 200, body: String(decoding: try fixtureData("wikipedia/missing-page.json"), as: UTF8.self))])
            let article = try await client(fluent, transport).article(site: "enwiki", title: "Zzzz Nonexistent Film Title 1234")
            #expect(article == nil)
        }
    }

    @Test func siteToLanguage() {
        #expect(WikipediaClient.language(forSite: "enwiki") == "en")
        #expect(WikipediaClient.language(forSite: "tawiki") == "ta")
        #expect(WikipediaClient.language(forSite: "ml") == "ml")
    }
}
