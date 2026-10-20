import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import Testing

@testable import NocturneServer

// MARK: - Fakes

private final class FakeJellyfin: JellyfinItemProviding, @unchecked Sendable {
    var item: BaseItemDto
    private(set) var fetches = 0
    init(item: BaseItemDto) { self.item = item }
    func fetchMovie(id: String) async throws -> BaseItemDto {
        fetches += 1
        return item
    }
}

private final class FakeResolver: WikidataResolving, @unchecked Sendable {
    var outcome: WikidataResolutionOutcome
    var error: Error? = nil
    private(set) var calls = 0
    init(_ outcome: WikidataResolutionOutcome) { self.outcome = outcome }
    func resolve(imdbId: String?, tmdbId: String?, title: String, year: Int?, context: CallContext) async throws -> WikidataResolutionOutcome {
        calls += 1
        if let error { throw error }
        return outcome
    }
}

private final class FakeWikipedia: WikipediaFetching, @unchecked Sendable {
    /// `site/title` to extract.
    var pages: [String: String]
    var error: Error? = nil
    private(set) var requested: [String] = []
    init(pages: [String: String]) { self.pages = pages }
    func article(site: String, title: String, context: CallContext) async throws -> WikipediaArticle? {
        requested.append("\(site)/\(title)")
        if let error { throw error }
        guard let extract = pages["\(site)/\(title)"] else { return nil }
        return WikipediaArticle(site: site, title: title, extract: extract)
    }
}

private final class FakeAwards: AwardsProviding, @unchecked Sendable {
    var awards: [Award] = []
    var omdb: String? = nil
    func awards(from resolution: WikidataResolution, context: CallContext) async throws -> [Award] { awards }
    func omdbAwards(imdbId: String, context: CallContext, now: Date) async -> String? { omdb }
}

private struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }

private func dto(lastSaved: String = "2026-05-01T10:00:00.0000000Z", imdb: String? = "tt0113277") -> BaseItemDto {
    BaseItemDto(
        id: "jf-heat", name: "Heat", originalTitle: "Heat", overview: "A thief and a cop.", productionYear: 1995,
        runTimeTicks: 102_000_000_000, genres: ["Crime", "Drama"],
        people: [
            BaseItemPerson(name: "Michael Mann", id: nil, role: nil, type: "Director", primaryImageTag: nil),
            BaseItemPerson(name: "Al Pacino", id: nil, role: "Vincent Hanna", type: "Actor", primaryImageTag: nil),
            BaseItemPerson(name: "Robert De Niro", id: nil, role: "Neil McCauley", type: "Actor", primaryImageTag: nil),
        ],
        imageTags: nil, backdropImageTags: nil,
        providerIds: imdb.map { ["Imdb": $0, "Tmdb": "949"] }, dateLastSaved: lastSaved)
}

private func heatResolution(sitelinks: [String: String] = ["enwiki": "Heat (1995 film)"]) -> WikidataResolution {
    WikidataResolution(
        qid: "Q42198", sitelinks: sitelinks, imdbId: "tt0113277", tmdbId: "949", instanceOf: ["Q11424"],
        publicationYears: [1995], awardsWon: [], awardsNominated: [])
}

private let englishExtract = """
Heat is a 1995 film.

== Plot ==
Neil robs a bank. Hanna takes McCauley's hand as he dies.

== Release ==
Released in December.

=== Critical reception ===
Critics liked it.
"""

private let tamilExtract = """
நாயகன் 1987 திரைப்படம்.

== கதை ==
வேலு நாயக்கர் கதை.

== விருதுகள் ==
தேசிய விருது.
"""

private let stubExtract = """
A stub about a film.

== Cast ==
People.

== Accolades ==
Won a prize.
"""

@Suite struct EnrichmentServiceTests {

    private func service(
        _ fluent: Fluent, jellyfin: FakeJellyfin, resolver: FakeResolver, wikipedia: FakeWikipedia, awards: FakeAwards = FakeAwards(),
        now: Date = Date(timeIntervalSince1970: 1_792_540_800)  // 2026-10-21 UTC
    ) -> EnrichmentService {
        EnrichmentService(fluent: fluent, jellyfin: jellyfin, resolver: resolver, wikipedia: wikipedia, awards: awards, logger: Logger(label: "test"), now: { now })
    }

    @Test func happyPathWritesAWikipediaRow() async throws {
        try await withTestFluent { fluent in
            let jellyfin = FakeJellyfin(item: dto())
            let resolver = FakeResolver(.resolved(heatResolution()))
            let wikipedia = FakeWikipedia(pages: ["enwiki/Heat (1995 film)": englishExtract])
            let awards = FakeAwards()
            awards.awards = [Award(name: "Saturn Award", kind: .nominated, year: 1996)]
            awards.omdb = "12 wins & 15 nominations total"
            let svc = service(fluent, jellyfin: jellyfin, resolver: resolver, wikipedia: wikipedia, awards: awards)

            let row = try await svc.enrich(jellyfinId: "jf-heat")
            #expect(row.source == "wikipedia")
            #expect(row.plotFound)
            #expect(!row.unverified)
            #expect(row.wikiSite == "enwiki")
            #expect(row.wikiTitle == "Heat (1995 film)")
            #expect(row.wikidataQid == "Q42198")
            #expect(row.imdbId == "tt0113277")
            #expect(row.tmdbId == "949")
            #expect(row.plotText == "Neil robs a bank. Hanna takes McCauley's hand as he dies.")
            #expect(row.receptionText == "Released in December.\n\nCritics liked it.")
            #expect(row.omdbAwards == "12 wins & 15 nominations total")
            #expect(row.awardsJson?.contains("Saturn Award") == true)
            #expect(row.inputHash?.count == 64)
            #expect(row.error == nil)
            #expect(row.jellyfinLastSaved == "2026-05-01T10:00:00.0000000Z")
            #expect(row.enrichVersion == TextBlockBuilder.version)
            let block = try #require(row.textBlock)
            #expect(block.contains("Title: Heat (1995)"))
            #expect(block.contains("Director: Michael Mann · Runtime: 170 min · Genres: Crime, Drama"))
            #expect(block.contains("Cast: Al Pacino, Robert De Niro"))
            #expect(block.contains("Nominated: Saturn Award (1996)"))
            #expect(block.hasSuffix("Page: Heat (1995 film) (en) · fetched 2026-10-21 · verified\n"))
            #expect(try await MovieEnrichment.query(on: fluent.db()).count() == 1)
        }
    }

    @Test func otherLanguagePageIsUsedWhenEnglishHasNoPlot() async throws {
        try await withTestFluent { fluent in
            let resolver = FakeResolver(.resolved(heatResolution(sitelinks: ["enwiki": "Stub", "tawiki": "நாயகன்"])))
            let wikipedia = FakeWikipedia(pages: ["enwiki/Stub": stubExtract, "tawiki/நாயகன்": tamilExtract])
            let svc = service(fluent, jellyfin: FakeJellyfin(item: dto()), resolver: resolver, wikipedia: wikipedia)

            let row = try await svc.enrich(jellyfinId: "jf-heat")
            #expect(row.source == "wikipedia_other_lang")
            #expect(row.wikiSite == "tawiki")
            #expect(row.plotText == "வேலு நாயக்கர் கதை.")
            #expect(row.receptionText == "தேசிய விருது.")
            #expect(wikipedia.requested == ["enwiki/Stub", "tawiki/நாயகன்"])
        }
    }

    @Test func noPlotAnywhereKeepsReceptionAndMarksNoSource() async throws {
        try await withTestFluent { fluent in
            let resolver = FakeResolver(.resolved(heatResolution(sitelinks: ["enwiki": "Stub"])))
            let wikipedia = FakeWikipedia(pages: ["enwiki/Stub": stubExtract])
            let svc = service(fluent, jellyfin: FakeJellyfin(item: dto()), resolver: resolver, wikipedia: wikipedia)

            let row = try await svc.enrich(jellyfinId: "jf-heat")
            #expect(row.source == "none")
            #expect(!row.plotFound)
            #expect(row.wikiTitle == "Stub")
            #expect(row.receptionText == "Won a prize.")
            #expect(row.textBlock?.contains("# Plot (Wikipedia, full, contains spoilers)\n(none)") == true)
            #expect(row.error == nil)
        }
    }

    @Test func unresolvedFilmIsRecordedWithoutError() async throws {
        try await withTestFluent { fluent in
            let resolver = FakeResolver(.unresolved(reason: "nothing matched"))
            let wikipedia = FakeWikipedia(pages: [:])
            let svc = service(fluent, jellyfin: FakeJellyfin(item: dto(imdb: nil)), resolver: resolver, wikipedia: wikipedia)

            let row = try await svc.enrich(jellyfinId: "jf-heat")
            #expect(row.source == "none")
            #expect(row.wikidataQid == nil)
            #expect(row.error == nil)
            #expect(row.textBlock != nil)
            #expect(wikipedia.requested.isEmpty)
        }
    }

    @Test func overrideSkipsResolutionAndWins() async throws {
        try await withTestFluent { fluent in
            let resolver = FakeResolver(.resolved(heatResolution(sitelinks: ["enwiki": "Wrong page"])))
            let wikipedia = FakeWikipedia(pages: ["enwiki/Wrong page": stubExtract, "enwiki/Heat (1995 film)": englishExtract])
            let svc = service(fluent, jellyfin: FakeJellyfin(item: dto()), resolver: resolver, wikipedia: wikipedia)

            _ = try await svc.enrich(jellyfinId: "jf-heat")
            #expect(resolver.calls == 1)
            let row = try await svc.override(jellyfinId: "jf-heat", site: "enwiki", title: "Heat (1995 film)")
            #expect(resolver.calls == 1)
            #expect(row.wikiTitleOverride == "Heat (1995 film)")
            #expect(row.plotFound)
            #expect(row.source == "wikipedia")
            #expect(wikipedia.requested.last == "enwiki/Heat (1995 film)")
        }
    }

    @Test func unchangedFilmSkipsTheNetworkUnlessForced() async throws {
        try await withTestFluent { fluent in
            let jellyfin = FakeJellyfin(item: dto())
            let resolver = FakeResolver(.resolved(heatResolution()))
            let wikipedia = FakeWikipedia(pages: ["enwiki/Heat (1995 film)": englishExtract])
            let svc = service(fluent, jellyfin: jellyfin, resolver: resolver, wikipedia: wikipedia)

            let first = try await svc.enrich(jellyfinId: "jf-heat")
            let firstFetched = first.fetchedAt
            _ = try await svc.enrich(jellyfinId: "jf-heat")
            #expect(resolver.calls == 1)
            #expect(wikipedia.requested.count == 1)
            #expect(try await svc.current(jellyfinId: "jf-heat")?.fetchedAt == firstFetched)

            jellyfin.item = dto(lastSaved: "2026-06-01T00:00:00.0000000Z")
            _ = try await svc.enrich(jellyfinId: "jf-heat")
            #expect(resolver.calls == 2)

            _ = try await svc.enrich(jellyfinId: "jf-heat", force: true)
            #expect(resolver.calls == 3)
            #expect(try await MovieEnrichment.query(on: fluent.db()).count() == 1)
        }
    }

    @Test func transientFailureIsRecordedAndKeepsGoodContent() async throws {
        try await withTestFluent { fluent in
            let resolver = FakeResolver(.resolved(heatResolution()))
            let wikipedia = FakeWikipedia(pages: ["enwiki/Heat (1995 film)": englishExtract])
            let svc = service(fluent, jellyfin: FakeJellyfin(item: dto()), resolver: resolver, wikipedia: wikipedia)

            // First run fails outright: a `none` row with the error, no throw.
            wikipedia.error = Boom()
            let failed = try await svc.enrich(jellyfinId: "jf-heat")
            #expect(failed.error == "boom")
            #expect(failed.source == "none")
            #expect(failed.textBlock == nil)

            // Recovery: the error row is retried (error != nil defeats the skip), content lands.
            wikipedia.error = nil
            let good = try await svc.enrich(jellyfinId: "jf-heat")
            #expect(good.error == nil)
            #expect(good.plotFound)

            // A later failure keeps the good block and only records the error.
            wikipedia.error = Boom()
            let later = try await svc.enrich(jellyfinId: "jf-heat", force: true)
            #expect(later.error == "boom")
            #expect(later.plotFound)
            #expect(later.textBlock != nil)
            #expect(later.source == "wikipedia")
        }
    }

    @Test func identityExtraction() {
        let identity = EnrichmentService.identity(from: dto())
        #expect(identity.director == "Michael Mann")
        #expect(identity.cast == ["Al Pacino", "Robert De Niro"])
        #expect(identity.runtimeMinutes == 170)
        #expect(identity.imdbId == "tt0113277")
        #expect(identity.tmdbId == "949")
        #expect(EnrichmentService.dayString(Date(timeIntervalSince1970: 1_792_540_800)) == "2026-10-21")
    }
}
