import FluentKit
import Foundation
import HummingbirdFluent
import Logging

// MARK: - Seams (production types conform; tests use fakes)

protocol JellyfinItemProviding: Sendable {
    func fetchMovie(id: String) async throws -> BaseItemDto
}

protocol WikidataResolving: Sendable {
    func resolve(imdbId: String?, tmdbId: String?, title: String, year: Int?, context: CallContext) async throws -> WikidataResolutionOutcome
}

protocol WikipediaFetching: Sendable {
    func article(site: String, title: String, context: CallContext) async throws -> WikipediaArticle?
}

protocol AwardsProviding: Sendable {
    func awards(from resolution: WikidataResolution, context: CallContext) async throws -> [Award]
    func omdbAwards(imdbId: String, context: CallContext, now: Date) async -> String?
}

extension JellyfinService: JellyfinItemProviding {}
extension WikidataResolver: WikidataResolving {}
extension WikipediaClient: WikipediaFetching {}
extension AwardsResolver: AwardsProviding {}

/// Strong-model synopsis writer for films with no story source anywhere.
protocol SynopsisWriting: Sendable {
    func isEnabled() async throws -> Bool
    func write(for identity: EnrichmentService.Identity, apiKey: String, context: CallContext) async throws -> SynopsisResult
}

typealias APIKeyProvider = @Sendable () async throws -> String?

// MARK: - Service

/// Builds and stores a film's story source: resolves the page, fetches plot and reception,
/// collects awards, writes the canonical text block and its hash into `movie_enrichment`.
/// A transient failure never destroys a good row; it is recorded in `error` instead.
final class EnrichmentService: Sendable {
    /// Candidate sites in preference order; the first one with a plot wins.
    static let siteOrder = ["enwiki", "tawiki", "mlwiki", "hiwiki", "knwiki", "tewiki", "bnwiki"]

    let fluent: Fluent
    let jellyfin: JellyfinItemProviding
    let resolver: WikidataResolving
    let wikipedia: WikipediaFetching
    let awards: AwardsProviding
    let synopsis: SynopsisWriting?
    let apiKey: APIKeyProvider
    let logger: Logger
    let now: @Sendable () -> Date

    init(
        fluent: Fluent, jellyfin: JellyfinItemProviding, resolver: WikidataResolving,
        wikipedia: WikipediaFetching, awards: AwardsProviding,
        synopsis: SynopsisWriting? = nil, apiKey: @escaping APIKeyProvider = { nil },
        logger: Logger = Logger(label: "Enrichment"), now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fluent = fluent
        self.jellyfin = jellyfin
        self.resolver = resolver
        self.wikipedia = wikipedia
        self.awards = awards
        self.synopsis = synopsis
        self.apiKey = apiKey
        self.logger = logger
        self.now = now
    }

    /// Writes a model synopsis for the film regardless of the fallback setting (admin action),
    /// stores it as the story source flagged `unverified`, and rebuilds the block.
    func generateSynopsis(jellyfinId: String, context: CallContext = .none) async throws -> MovieEnrichment {
        guard let synopsis else { throw EnrichmentError.synopsisUnavailable }
        guard let key = try await apiKey(), !key.isEmpty else { throw TaggerError.missingAnthropicKey }
        let row = try await current(jellyfinId: jellyfinId) ?? MovieEnrichment(jellyfinId: jellyfinId)
        let identity: Identity
        if let json = row.identityJson, let decoded = try? JSONDecoder().decode(Identity.self, from: Data(json.utf8)) {
            identity = decoded
        } else {
            let dto = try await jellyfin.fetchMovie(id: jellyfinId)
            identity = Self.identity(from: dto)
            row.identityJson = Self.json(identity)
            row.overviewText = identity.overview
            row.imdbId = identity.imdbId
            row.tmdbId = identity.tmdbId
        }
        let result = try await synopsis.write(for: identity, apiKey: key, context: context)
        try await store(modelSynopsis: result, identity: identity, on: row)
        return row
    }

    func current(jellyfinId: String) async throws -> MovieEnrichment? {
        try await MovieEnrichment.find(jellyfinId, on: fluent.db())
    }

    /// Sets a page override and rebuilds at once.
    func override(jellyfinId: String, site: String, title: String, context: CallContext = .none) async throws -> MovieEnrichment {
        let row = try await current(jellyfinId: jellyfinId) ?? MovieEnrichment(jellyfinId: jellyfinId)
        row.wikiSite = site
        row.wikiTitleOverride = title
        try await row.save(on: fluent.db())
        return try await enrich(jellyfinId: jellyfinId, force: true, context: context)
    }

    /// Enriches one film. Pass `item` when the caller already holds the Jellyfin DTO. Skips the
    /// network entirely when nothing changed since the last successful build, unless `force`.
    func enrich(
        jellyfinId: String, item: BaseItemDto? = nil, force: Bool = false, context: CallContext = .none
    ) async throws -> MovieEnrichment {
        let db = fluent.db()
        let existing = try await current(jellyfinId: jellyfinId)
        let dto: BaseItemDto
        if let item {
            dto = item
        } else {
            dto = try await jellyfin.fetchMovie(id: jellyfinId)
        }

        if !force, let existing, existing.textBlock != nil, existing.error == nil,
            existing.enrichVersion == TextBlockBuilder.version,
            existing.jellyfinLastSaved == dto.dateLastSaved
        {
            return existing
        }

        let row = existing ?? MovieEnrichment(jellyfinId: jellyfinId)
        let identity = Self.identity(from: dto)
        row.imdbId = identity.imdbId
        row.tmdbId = identity.tmdbId
        row.identityJson = Self.json(identity)
        row.overviewText = identity.overview

        do {
            let built = try await fetchStory(for: identity, row: row, context: context)
            row.wikidataQid = built.qid
            row.wikiSite = built.site ?? row.wikiSite
            row.wikiTitle = built.pageTitle
            row.plotText = built.plot
            row.receptionText = built.reception
            row.awardsJson = Self.json(built.awards)
            row.omdbAwards = built.omdbAwards
            row.source = built.source.rawValue
            row.unverified = built.unverified
            row.plotFound = built.plot != nil
            let input = TextBlockInput(
                title: identity.title, originalTitle: identity.originalTitle, year: identity.year,
                director: identity.director, runtimeMinutes: identity.runtimeMinutes, genres: identity.genres,
                cast: identity.cast, overview: identity.overview, plot: built.plot, reception: built.reception,
                awards: built.awards, omdbAwards: built.omdbAwards, pageTitle: built.pageTitle, pageSite: built.site,
                fetchedOn: Self.dayString(now()), source: built.source, unverified: built.unverified)
            let (block, hash) = TextBlockBuilder.build(input)
            row.textBlock = block
            row.inputHash = hash
            row.enrichVersion = TextBlockBuilder.version
            row.jellyfinLastSaved = dto.dateLastSaved
            row.fetchedAt = now()
            row.error = nil
            try await row.save(on: db)
            logger.info("[\(jellyfinId)] enriched: source=\(built.source.rawValue) plot=\(built.plot != nil) site=\(built.site ?? "-")")
            return row
        } catch {
            // Keep whatever good content the row already had; surface the failure.
            row.error = String(describing: error)
            if row.textBlock == nil {
                row.source = EnrichmentSource.none.rawValue
                row.plotFound = false
                row.enrichVersion = TextBlockBuilder.version
                row.jellyfinLastSaved = dto.dateLastSaved
            }
            try await row.save(on: db)
            logger.warning("[\(jellyfinId)] enrichment failed: \(error)")
            return row
        }
    }

    // MARK: Story fetch

    struct Built: Sendable {
        var qid: String?
        var site: String?
        var pageTitle: String?
        var plot: String?
        var reception: String?
        var awards: [Award] = []
        var omdbAwards: String?
        var source: EnrichmentSource = .none
        var unverified = false
    }

    /// Stores a model-written synopsis on the row and rebuilds the block (source `model`, unverified).
    private func store(modelSynopsis result: SynopsisResult, identity: Identity, on row: MovieEnrichment) async throws {
        row.plotText = result.plot
        if !result.reception.isEmpty { row.receptionText = result.reception }
        row.source = EnrichmentSource.model.rawValue
        row.unverified = true
        row.plotFound = true
        row.wikiTitle = nil
        let awards = (row.awardsJson.flatMap { try? JSONDecoder().decode([Award].self, from: Data($0.utf8)) }) ?? []
        let input = TextBlockInput(
            title: identity.title, originalTitle: identity.originalTitle, year: identity.year,
            director: identity.director, runtimeMinutes: identity.runtimeMinutes, genres: identity.genres,
            cast: identity.cast, overview: identity.overview, plot: row.plotText, reception: row.receptionText,
            awards: awards, omdbAwards: row.omdbAwards, pageTitle: nil, pageSite: nil,
            fetchedOn: Self.dayString(now()), source: .model, unverified: true)
        let (block, hash) = TextBlockBuilder.build(input)
        row.textBlock = block
        row.inputHash = hash
        row.enrichVersion = TextBlockBuilder.version
        row.fetchedAt = now()
        row.error = nil
        try await row.save(on: fluent.db())
        logger.info("[\(row.jellyfinId)] model synopsis stored (unverified), \(result.sources.count) sources")
    }

    private func fetchStory(for identity: Identity, row: MovieEnrichment, context: CallContext) async throws -> Built {
        var built = Built()

        // Page candidates: an admin override wins; otherwise resolve through Wikidata.
        var candidates: [(site: String, title: String)] = []
        var resolution: WikidataResolution? = nil
        if let overrideTitle = row.wikiTitleOverride, let site = row.wikiSite {
            candidates = [(site, overrideTitle)]
        } else {
            let outcome = try await resolver.resolve(
                imdbId: identity.imdbId, tmdbId: identity.tmdbId, title: identity.title, year: identity.year, context: context)
            switch outcome {
            case .resolved(let r):
                resolution = r
                built.qid = r.qid
                for site in Self.siteOrder {
                    if let title = r.sitelinks[site] { candidates.append((site, title)) }
                }
            case .unresolved(let reason):
                logger.info("[\(identity.title)] unresolved: \(reason)")
            }
        }

        // First candidate with a plot wins; otherwise keep the first article for its reception.
        var firstArticle: (site: String, article: WikipediaArticle, parsed: ParsedArticle)? = nil
        for candidate in candidates {
            guard let article = try await wikipedia.article(site: candidate.site, title: candidate.title, context: context) else { continue }
            let parsed = SectionParser.parse(article.extract)
            let language = WikipediaClient.language(forSite: candidate.site)
            if firstArticle == nil { firstArticle = (candidate.site, article, parsed) }
            if let plot = SectionParser.plot(from: parsed, language: language) {
                built.site = candidate.site
                built.pageTitle = article.title
                built.plot = plot
                built.reception = SectionParser.reception(from: parsed, language: language)
                built.source = candidate.site == "enwiki" ? .wikipedia : .wikipediaOtherLang
                break
            }
        }
        if built.plot == nil, let first = firstArticle {
            let language = WikipediaClient.language(forSite: first.site)
            built.site = first.site
            built.pageTitle = first.article.title
            built.reception = SectionParser.reception(from: first.parsed, language: language)
            // A page without a story section is not a story source; the block says `(none)`.
            built.source = .none
        }

        // Last resort, only when switched on: a strong model writes the story, flagged unverified.
        if built.plot == nil, let synopsis, try await synopsis.isEnabled(), let key = try await apiKey(), !key.isEmpty {
            let written = try await synopsis.write(for: identity, apiKey: key, context: context)
            built.plot = written.plot
            built.reception = written.reception.isEmpty ? built.reception : written.reception
            built.source = .model
            built.unverified = true
        }

        if let resolution {
            built.awards = try await awards.awards(from: resolution, context: context)
        }
        if let imdb = identity.imdbId {
            built.omdbAwards = await awards.omdbAwards(imdbId: imdb, context: context, now: now())
        }
        return built
    }

    // MARK: Identity

    struct Identity: Codable, Sendable, Equatable {
        var title: String
        var originalTitle: String?
        var year: Int?
        var director: String?
        var runtimeMinutes: Int?
        var genres: [String]
        var cast: [String]
        var overview: String?
        var imdbId: String?
        var tmdbId: String?
    }

    static func identity(from dto: BaseItemDto) -> Identity {
        let people = dto.people ?? []
        let director = people.first { ($0.type ?? "").lowercased() == "director" }?.name
        let cast = people.filter { ($0.type ?? "").lowercased() == "actor" }.compactMap(\.name)
        let imdb = WikidataResolver.normalizeImdb(dto.providerIds?["Imdb"] ?? dto.providerIds?["imdb"])
        let tmdb = (dto.providerIds?["Tmdb"] ?? dto.providerIds?["tmdb"])?.trimmingCharacters(in: .whitespaces)
        return Identity(
            title: dto.name ?? "", originalTitle: dto.originalTitle, year: dto.productionYear,
            director: director, runtimeMinutes: dto.runTimeTicks.map { Int($0 / 600_000_000) },
            genres: dto.genres ?? [], cast: Array(cast.prefix(TextBlockBuilder.castLimit)),
            overview: dto.overview, imdbId: imdb, tmdbId: (tmdb?.isEmpty == false) ? tmdb : nil)
    }

    static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

enum EnrichmentError: Error, CustomStringConvertible {
    case synopsisUnavailable
    var description: String {
        switch self {
        case .synopsisUnavailable: return "model synopsis is not configured on this server"
        }
    }
}
