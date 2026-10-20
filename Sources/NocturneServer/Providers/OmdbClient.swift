import AsyncHTTPClient
import Foundation
import NIOCore

/// The subset of an OMDb `?i=<imdb>` response the server reads.
struct OmdbPayload: Codable, Sendable {
    let Ratings: [OmdbRating]?
    let Awards: String?
    let Response: String?

    var isOk: Bool { Response?.lowercased() == "true" }
    var ratings: [OmdbRating] { Ratings ?? [] }
    /// OMDb writes "N/A" when it has nothing; that is not an awards string.
    var awards: String? {
        guard let a = Awards?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty, a.uppercased() != "N/A" else { return nil }
        return a
    }
}

/// OMDb over `OutboundClient`, so every call is metered and retried like every other provider.
struct OmdbClient: Sendable {
    static let baseURL = "http://www.omdbapi.com/"

    let outbound: OutboundClient
    var url: String = OmdbClient.baseURL

    /// The payload, or nil when OMDb answers `Response: False` (unknown id).
    func fetch(imdbId: String, apiKey: String, context: CallContext = .none) async throws -> OmdbPayload? {
        var components = URLComponents(string: url)!
        components.queryItems = [
            URLQueryItem(name: "apikey", value: apiKey),
            URLQueryItem(name: "i", value: imdbId),
        ]
        var request = HTTPClientRequest(url: components.url!.absoluteString)
        request.method = .GET
        let response = try await outbound.send(
            provider: "omdb", endpoint: "/", request: request, timeout: .seconds(20), context: context
        ) { _ in CallUnits(calls: 1) }
        let payload = try response.decode(OmdbPayload.self)
        return payload.isOk ? payload : nil
    }
}
