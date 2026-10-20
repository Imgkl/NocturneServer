import FluentKit
import Foundation
import HummingbirdFluent
import Logging

@testable import NocturneServer

// MARK: - Fakes

final class FakeJellyfin: JellyfinItemProviding, @unchecked Sendable {
    var item: BaseItemDto
    private(set) var fetches = 0
    init(item: BaseItemDto) { self.item = item }
    func fetchMovie(id: String) async throws -> BaseItemDto {
        fetches += 1
        return item
    }
}

final class FakeResolver: WikidataResolving, @unchecked Sendable {
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

final class FakeWikipedia: WikipediaFetching, @unchecked Sendable {
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

final class FakeAwards: AwardsProviding, @unchecked Sendable {
    var awards: [Award] = []
    var omdb: String? = nil
    func awards(from resolution: WikidataResolution, context: CallContext) async throws -> [Award] { awards }
    func omdbAwards(imdbId: String, context: CallContext, now: Date) async -> String? { omdb }
}

struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }

func dto(lastSaved: String = "2026-05-01T10:00:00.0000000Z", imdb: String? = "tt0113277") -> BaseItemDto {
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

func heatResolution(sitelinks: [String: String] = ["enwiki": "Heat (1995 film)"]) -> WikidataResolution {
    WikidataResolution(
        qid: "Q42198", sitelinks: sitelinks, imdbId: "tt0113277", tmdbId: "949", instanceOf: ["Q11424"],
        publicationYears: [1995], awardsWon: [], awardsNominated: [])
}

let englishExtract = """
Heat is a 1995 film.

== Plot ==
Neil robs a bank. Hanna takes McCauley's hand as he dies.

== Release ==
Released in December.

=== Critical reception ===
Critics liked it.
"""

let tamilExtract = """
நாயகன் 1987 திரைப்படம்.

== கதை ==
வேலு நாயக்கர் கதை.

== விருதுகள் ==
தேசிய விருது.
"""

let stubExtract = """
A stub about a film.

== Cast ==
People.

== Accolades ==
Won a prize.
"""
