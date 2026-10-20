import AsyncHTTPClient
import Foundation
import NIOCore

// MARK: - Result types

struct AwardClaim: Sendable, Equatable, Codable {
    let qid: String
    let year: Int?
}

/// What Wikidata knows about one film, reduced to what enrichment needs.
struct WikidataResolution: Sendable, Equatable {
    let qid: String
    /// Site id to page title, for example `"enwiki": "Heat (1995 film)"`.
    let sitelinks: [String: String]
    let imdbId: String?
    let tmdbId: String?
    let instanceOf: [String]
    let publicationYears: [Int]
    let awardsWon: [AwardClaim]
    let awardsNominated: [AwardClaim]

    var enwikiTitle: String? { sitelinks["enwiki"] }

    /// `P31` contains a film class. Empty `P31` counts as unknown, not as a film.
    var isFilm: Bool {
        !Set(instanceOf).isDisjoint(with: WikidataResolver.filmClasses)
    }

    func yearMatches(_ year: Int?) -> Bool {
        guard let year, !publicationYears.isEmpty else { return true }
        return publicationYears.contains { abs($0 - year) <= 1 }
    }
}

enum WikidataResolutionOutcome: Sendable, Equatable {
    case resolved(WikidataResolution)
    case unresolved(reason: String)

    var resolution: WikidataResolution? {
        if case .resolved(let r) = self { return r }
        return nil
    }
}

// MARK: - Resolver

/// Resolves a Jellyfin film to a Wikidata entity: IMDb id first, then TMDb id, then a title
/// search filtered to films with a matching year. Every hit is cross-checked against the
/// entity's own claims, because Wikidata search returns placeholder ids too.
struct WikidataResolver: Sendable {
    static let apiURL = "https://www.wikidata.org/w/api.php"
    static let sitefilter = ["enwiki", "tawiki", "mlwiki", "hiwiki", "knwiki", "tewiki", "bnwiki"]
    /// Q11424 film, Q24869 feature film, Q226730 silent film, Q202866 animated film,
    /// Q229390 3D film, Q506240 television film, Q93204 documentary film, Q20650540 anime film,
    /// Q24862 short film, Q2484376 thriller film, Q319221 adventure film, Q52162262 film series? no:
    /// kept to classes that are films themselves.
    static let filmClasses: Set<String> = [
        "Q11424", "Q24869", "Q226730", "Q202866", "Q229390", "Q506240", "Q93204", "Q20650540", "Q24862",
    ]

    let outbound: OutboundClient
    let limiter: RateLimiter
    let userAgent: String
    var url: String = WikidataResolver.apiURL
    var titleCandidates: Int = 5

    func resolve(
        imdbId: String?, tmdbId: String?, title: String, year: Int?, context: CallContext = .none
    ) async throws -> WikidataResolutionOutcome {
        var reasons: [String] = []

        if let imdb = Self.normalizeImdb(imdbId) {
            if let qid = try await searchQid(statement: "P345=\(imdb)", context: context) {
                let entity = try await entity(qid, context: context)
                if entity.imdbId?.lowercased() == imdb.lowercased(), entity.yearMatches(year) {
                    return .resolved(entity)
                }
                reasons.append("imdb \(imdb) resolved to \(qid) but its claims did not match")
            } else {
                reasons.append("no entity carries imdb \(imdb)")
            }
        }

        if let tmdb = tmdbId?.trimmingCharacters(in: .whitespaces), !tmdb.isEmpty {
            if let qid = try await searchQid(statement: "P4947=\(tmdb)", context: context) {
                let entity = try await entity(qid, context: context)
                if entity.tmdbId == tmdb, entity.yearMatches(year) {
                    return .resolved(entity)
                }
                reasons.append("tmdb \(tmdb) resolved to \(qid) but its claims did not match")
            } else {
                reasons.append("no entity carries tmdb \(tmdb)")
            }
        }

        let candidates = try await searchByTitle(title, context: context)
        for candidate in candidates.prefix(titleCandidates) {
            let entity = try await entity(candidate, context: context)
            guard entity.isFilm else { continue }
            guard entity.yearMatches(year) else { continue }
            guard entity.imdbId != nil || entity.tmdbId != nil else { continue }
            return .resolved(entity)
        }
        reasons.append("title search for \"\(title)\" (\(year.map(String.init) ?? "no year")) found no matching film among \(candidates.count) candidates")
        return .unresolved(reason: reasons.joined(separator: "; "))
    }

    // MARK: Calls

    private func searchQid(statement: String, context: CallContext) async throws -> String? {
        let response = try await get(
            endpoint: "query/search",
            params: ["action": "query", "list": "search", "srsearch": "haswbstatement:\(statement)", "srlimit": "3", "format": "json"],
            context: context)
        let decoded = try response.decode(SearchResponse.self)
        return decoded.query?.search?.first?.title
    }

    private func searchByTitle(_ title: String, context: CallContext) async throws -> [String] {
        let response = try await get(
            endpoint: "wbsearchentities",
            params: ["action": "wbsearchentities", "search": title, "language": "en", "type": "item", "limit": "\(titleCandidates)", "format": "json"],
            context: context)
        let decoded = try response.decode(EntitySearchResponse.self)
        return (decoded.search ?? []).map(\.id)
    }

    func entity(_ qid: String, context: CallContext) async throws -> WikidataResolution {
        let response = try await get(
            endpoint: "wbgetentities",
            params: ["action": "wbgetentities", "ids": qid, "props": "sitelinks|claims", "sitefilter": Self.sitefilter.joined(separator: "|"), "format": "json"],
            context: context)
        let decoded = try response.decode(EntitiesResponse.self)
        guard let entity = decoded.entities?[qid] else {
            throw WikidataError.missingEntity(qid)
        }
        return Self.reduce(qid: qid, entity: entity)
    }

    private func get(endpoint: String, params: [String: String], context: CallContext) async throws -> OutboundResponse {
        try await limiter.acquire()
        var components = URLComponents(string: url)!
        components.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = HTTPClientRequest(url: components.url!.absoluteString)
        request.method = .GET
        request.headers.add(name: "User-Agent", value: userAgent)
        request.headers.add(name: "Accept", value: "application/json")
        return try await outbound.send(
            provider: "wikidata", endpoint: endpoint, request: request, timeout: .seconds(20), context: context
        ) { _ in CallUnits(calls: 1) }
    }

    // MARK: Reduction

    static func reduce(qid: String, entity: Entity) -> WikidataResolution {
        let claims = entity.claims ?? [:]
        func strings(_ property: String) -> [String] {
            (claims[property] ?? []).compactMap { $0.mainsnak.datavalue?.value.string }
        }
        func items(_ property: String) -> [String] {
            (claims[property] ?? []).compactMap { $0.mainsnak.datavalue?.value.itemId }
        }
        func awards(_ property: String) -> [AwardClaim] {
            (claims[property] ?? []).compactMap { claim -> AwardClaim? in
                guard let id = claim.mainsnak.datavalue?.value.itemId else { return nil }
                let year = claim.qualifiers?["P585"]?.first?.datavalue?.value.time.flatMap(Self.year(fromWikidataTime:))
                return AwardClaim(qid: id, year: year)
            }
        }
        let years = (claims["P577"] ?? []).compactMap { $0.mainsnak.datavalue?.value.time }.compactMap(Self.year(fromWikidataTime:))
        var sitelinks: [String: String] = [:]
        for (site, link) in entity.sitelinks ?? [:] {
            sitelinks[site] = link.title
        }
        return WikidataResolution(
            qid: qid,
            sitelinks: sitelinks,
            imdbId: strings("P345").first,
            tmdbId: strings("P4947").first,
            instanceOf: items("P31"),
            publicationYears: Array(Set(years)).sorted(),
            awardsWon: awards("P166"),
            awardsNominated: awards("P1411"))
    }

    /// `+2019-05-30T00:00:00Z` or `+2019-00-00T00:00:00Z` to 2019.
    static func year(fromWikidataTime time: String) -> Int? {
        var s = Substring(time)
        if s.first == "+" || s.first == "-" { s = s.dropFirst() }
        guard let dash = s.firstIndex(of: "-") else { return Int(s) }
        return Int(s[s.startIndex..<dash])
    }

    static func normalizeImdb(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        guard raw.hasPrefix("tt"), raw.dropFirst(2).allSatisfy(\.isNumber) else { return nil }
        return raw
    }

    // MARK: Wire types

    struct SearchResponse: Decodable {
        struct Query: Decodable {
            struct Hit: Decodable { let title: String }
            let search: [Hit]?
        }
        let query: Query?
    }

    struct EntitySearchResponse: Decodable {
        struct Hit: Decodable { let id: String }
        let search: [Hit]?
    }

    struct EntitiesResponse: Decodable {
        let entities: [String: Entity]?
    }

    struct Entity: Decodable {
        struct Sitelink: Decodable { let title: String }
        let claims: [String: [Claim]]?
        let sitelinks: [String: Sitelink]?
    }

    struct Claim: Decodable {
        let mainsnak: Snak
        let qualifiers: [String: [Snak]]?
    }

    struct Snak: Decodable {
        let snaktype: String
        let datavalue: DataValue?
    }

    struct DataValue: Decodable {
        let value: Value
    }

    /// Wikidata datavalues vary by type: a bare string (external ids), an item reference,
    /// or a time. Anything else is kept as `.other`.
    enum Value: Decodable {
        case string(String)
        case item(String)
        case time(String)
        case other

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let s = try? container.decode(String.self) {
                self = .string(s)
                return
            }
            if let dict = try? container.decode([String: AnyJSON].self) {
                if case .string(let id)? = dict["id"] { self = .item(id); return }
                if case .string(let time)? = dict["time"] { self = .time(time); return }
            }
            self = .other
        }

        var string: String? { if case .string(let s) = self { return s } else { return nil } }
        var itemId: String? { if case .item(let s) = self { return s } else { return nil } }
        var time: String? { if case .time(let s) = self { return s } else { return nil } }
    }
}

enum WikidataError: Error, CustomStringConvertible {
    case missingEntity(String)
    var description: String {
        switch self {
        case .missingEntity(let qid): return "Wikidata returned no entity for \(qid)"
        }
    }
}

/// Minimal JSON value for decoding heterogeneous dictionaries.
enum AnyJSON: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: AnyJSON])
    case array([AnyJSON])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([AnyJSON].self) { self = .array(a); return }
        if let o = try? c.decode([String: AnyJSON].self) { self = .object(o); return }
        self = .null
    }
}
