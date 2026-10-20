import AsyncHTTPClient
import Foundation
import NIOCore

struct WikipediaArticle: Sendable, Equatable {
    let site: String
    let title: String
    let extract: String
}

/// Fetches a page as plain text with wiki-style section headings from any Wikipedia language
/// edition, through `OutboundClient` and the shared Wikimedia rate limiter.
struct WikipediaClient: Sendable {
    let outbound: OutboundClient
    let limiter: RateLimiter
    let userAgent: String
    /// Overridable for tests; defaults to `https://<lang>.wikipedia.org/w/api.php`.
    var endpoint: @Sendable (String) -> String = { site in
        "https://\(WikipediaClient.language(forSite: site)).wikipedia.org/w/api.php"
    }

    /// `enwiki` to `en`, `tawiki` to `ta`.
    static func language(forSite site: String) -> String {
        site.hasSuffix("wiki") ? String(site.dropLast(4)) : site
    }

    /// The article, or nil when the page does not exist. Redirects are followed.
    func article(site: String, title: String, context: CallContext = .none) async throws -> WikipediaArticle? {
        try await limiter.acquire()
        var components = URLComponents(string: endpoint(site))!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "prop", value: "extracts"),
            URLQueryItem(name: "explaintext", value: "1"),
            URLQueryItem(name: "exsectionformat", value: "wiki"),
            URLQueryItem(name: "redirects", value: "1"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "titles", value: title),
        ]
        var request = HTTPClientRequest(url: components.url!.absoluteString)
        request.method = .GET
        request.headers.add(name: "User-Agent", value: userAgent)
        request.headers.add(name: "Accept", value: "application/json")

        let response = try await outbound.send(
            provider: "wikimedia", endpoint: "\(site)/extracts", request: request,
            timeout: .seconds(20), context: context
        ) { _ in CallUnits(calls: 1) }

        let decoded = try response.decode(ExtractsResponse.self)
        guard let page = decoded.query?.pages?.values.first, page.missing == nil, let extract = page.extract else {
            return nil
        }
        return WikipediaArticle(site: site, title: page.title ?? title, extract: extract)
    }

    struct ExtractsResponse: Decodable {
        struct Query: Decodable {
            let pages: [String: Page]?
        }
        struct Page: Decodable {
            let title: String?
            let extract: String?
            let missing: String?
        }
        let query: Query?
    }
}
