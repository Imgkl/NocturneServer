import AsyncHTTPClient
import FluentKit
import FluentSQL
import Foundation
import HummingbirdFluent
import Logging
import NIOCore

/// One award line for the text block.
struct Award: Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable {
        case won
        case nominated
    }

    let name: String
    let kind: Kind
    let year: Int?
}

/// Turns Wikidata award claims into named awards (with a persistent label cache) and fetches
/// OMDb's awards summary directly, best-effort, under a daily call cap.
final class AwardsResolver: Sendable {
    static let labelBatchSize = 50
    static let omdbKeySetting = "omdb_api_key"

    let outbound: OutboundClient
    let fluent: Fluent
    let limiter: RateLimiter
    let userAgent: String
    let omdb: OmdbClient
    let omdbCache: OmdbCacheStore
    let settings: SettingsStore
    let dailyOmdbCap: Int
    let logger: Logger
    let wikidataURL: String

    init(
        outbound: OutboundClient, fluent: Fluent, limiter: RateLimiter, userAgent: String,
        omdb: OmdbClient, omdbCache: OmdbCacheStore, settings: SettingsStore,
        dailyOmdbCap: Int = 900, logger: Logger = Logger(label: "Awards"),
        wikidataURL: String = WikidataResolver.apiURL
    ) {
        self.wikidataURL = wikidataURL
        self.outbound = outbound
        self.fluent = fluent
        self.limiter = limiter
        self.userAgent = userAgent
        self.omdb = omdb
        self.omdbCache = omdbCache
        self.settings = settings
        self.dailyOmdbCap = dailyOmdbCap
        self.logger = logger
    }

    // MARK: Wikidata labels

    /// English labels for award items, from `wikidata_labels` first and Wikidata in batches of
    /// 50 for the misses. Items with no English label are skipped.
    func labels(for qids: [String], context: CallContext = .none) async throws -> [String: String] {
        let unique = Array(Set(qids)).sorted()
        guard !unique.isEmpty else { return [:] }
        var result: [String: String] = [:]
        let cached = try await WikidataLabel.query(on: fluent.db()).filter(\.$id ~~ unique).all()
        for row in cached {
            if let qid = row.id { result[qid] = row.label }
        }
        let missing = unique.filter { result[$0] == nil }
        var start = 0
        while start < missing.count {
            let batch = Array(missing[start..<min(start + Self.labelBatchSize, missing.count)])
            start += Self.labelBatchSize
            let fetched = try await fetchLabels(batch, context: context)
            for (qid, label) in fetched {
                result[qid] = label
                try await store(qid: qid, label: label)
            }
        }
        return result
    }

    /// Upsert. The coverage job runs three films at once, so two workers can miss the same label
    /// and both try to insert it; the loser must not fail its film.
    private func store(qid: String, label: String) async throws {
        guard let sql = fluent.db() as? SQLDatabase else {
            try await WikidataLabel(qid: qid, label: label).save(on: fluent.db())
            return
        }
        try await sql.raw(
            "INSERT INTO wikidata_labels (qid, label, fetched_at) VALUES (\(bind: qid), \(bind: label), \(bind: Date().timeIntervalSince1970)) ON CONFLICT(qid) DO UPDATE SET label = excluded.label, fetched_at = excluded.fetched_at"
        ).run()
    }

    private func fetchLabels(_ qids: [String], context: CallContext) async throws -> [String: String] {
        try await limiter.acquire()
        var components = URLComponents(string: wikidataURL)!
        components.queryItems = [
            URLQueryItem(name: "action", value: "wbgetentities"),
            URLQueryItem(name: "ids", value: qids.joined(separator: "|")),
            URLQueryItem(name: "props", value: "labels"),
            URLQueryItem(name: "languages", value: "en"),
            URLQueryItem(name: "format", value: "json"),
        ]
        var request = HTTPClientRequest(url: components.url!.absoluteString)
        request.method = .GET
        request.headers.add(name: "User-Agent", value: userAgent)
        request.headers.add(name: "Accept", value: "application/json")
        let response = try await outbound.send(
            provider: "wikidata", endpoint: "wbgetentities/labels", request: request,
            timeout: .seconds(20), context: context
        ) { _ in CallUnits(calls: 1) }
        let decoded = try response.decode(LabelsResponse.self)
        var out: [String: String] = [:]
        for (qid, entity) in decoded.entities ?? [:] {
            if let value = entity.labels?["en"]?.value { out[qid] = value }
        }
        return out
    }

    /// Named awards from a resolution, won first, then by year descending, then by name.
    func awards(from resolution: WikidataResolution, context: CallContext = .none) async throws -> [Award] {
        let qids = (resolution.awardsWon + resolution.awardsNominated).map(\.qid)
        let names = try await labels(for: qids, context: context)
        func build(_ claims: [AwardClaim], _ kind: Award.Kind) -> [Award] {
            claims.compactMap { claim in
                guard let name = names[claim.qid] else { return nil }
                return Award(name: name, kind: kind, year: claim.year)
            }
        }
        let sortRule: (Award, Award) -> Bool = { a, b in
            if (a.year ?? -1) != (b.year ?? -1) { return (a.year ?? -1) > (b.year ?? -1) }
            return a.name < b.name
        }
        var won = build(resolution.awardsWon, .won)
        var nominated = build(resolution.awardsNominated, .nominated)
        won = Array(Set(won)).sorted(by: sortRule)
        nominated = Array(Set(nominated)).sorted(by: sortRule)
        return won + nominated
    }

    // MARK: OMDb

    /// OMDb calls made since local midnight, from `api_calls`.
    func omdbCallsToday(now: Date = Date()) async throws -> Int {
        let start = Calendar.current.startOfDay(for: now)
        return try await ApiCall.query(on: fluent.db())
            .filter(\.$provider == "omdb")
            .filter(\.$createdAt >= start)
            .count()
    }

    /// OMDb's awards summary: cached row first; otherwise one fetch when a key is configured
    /// and today's cap is not reached. Stores ratings and awards together, so the ratings
    /// proxy benefits too. Never throws; enrichment must not fail on OMDb.
    func omdbAwards(imdbId: String, context: CallContext = .none, now: Date = Date()) async -> String? {
        do {
            try await omdbCache.ensureTable()
            if let cached = try await omdbCache.get(imdbId: imdbId) {
                return cached.awards
            }
            guard let key = try await settings.get(Self.omdbKeySetting), !key.isEmpty else {
                return nil
            }
            let used = try await omdbCallsToday(now: now)
            guard used < dailyOmdbCap else {
                logger.info("OMDb daily cap reached (\(used)/\(dailyOmdbCap)); skipping \(imdbId) until tomorrow")
                return nil
            }
            guard let payload = try await omdb.fetch(imdbId: imdbId, apiKey: key, context: context) else {
                return nil
            }
            try await omdbCache.set(imdbId: imdbId, ratings: payload.ratings, awards: payload.awards)
            return payload.awards
        } catch {
            logger.warning("OMDb awards lookup failed for \(imdbId): \(error)")
            return nil
        }
    }

    struct LabelsResponse: Decodable {
        struct Entity: Decodable {
            struct Label: Decodable { let value: String }
            let labels: [String: Label]?
        }
        let entities: [String: Entity]?
    }
}
