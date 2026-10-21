import Crypto
import Foundation

/// Everything that goes into a film's canonical text block.
struct TextBlockInput: Sendable, Equatable {
    var title: String
    var originalTitle: String? = nil
    var year: Int? = nil
    var director: String? = nil
    var runtimeMinutes: Int? = nil
    var genres: [String] = []
    var cast: [String] = []
    var overview: String? = nil
    var lead: String? = nil
    var plot: String? = nil
    var reception: String? = nil
    var awards: [Award] = []
    var omdbAwards: String? = nil
    var pageTitle: String? = nil
    var pageSite: String? = nil
    var fetchedOn: String
    var source: EnrichmentSource = .none
    var unverified: Bool = false
}

/// Builds the one text every model reads. Deterministic: fixed headings, fixed order, missing
/// sections written as `(none)`. The hash covers everything except the `# Source` section, so a
/// re-fetch on a later date with identical content keeps its hash and does not trigger
/// re-classification.
enum TextBlockBuilder {
    /// Bump when the block format changes; every row with an older version is rebuilt.
    /// 2: the Wikipedia lead (country, language, standing) sits between Identity and Overview.
    static let version = 2
    static let castLimit = 5
    static let none = "(none)"

    static func build(_ input: TextBlockInput) -> (block: String, hash: String) {
        var out: [String] = []

        out.append("# Identity")
        var titleLine = "Title: \(input.title.trimmingCharacters(in: .whitespaces))"
        if let year = input.year { titleLine += " (\(year))" }
        if let original = input.originalTitle?.trimmingCharacters(in: .whitespaces), !original.isEmpty, original != input.title {
            titleLine += " · Original title: \(original)"
        }
        out.append(titleLine)
        var facts: [String] = []
        if let director = input.director, !director.isEmpty { facts.append("Director: \(director)") }
        if let runtime = input.runtimeMinutes, runtime > 0 { facts.append("Runtime: \(runtime) min") }
        if !input.genres.isEmpty { facts.append("Genres: \(input.genres.joined(separator: ", "))") }
        out.append(facts.isEmpty ? none : facts.joined(separator: " · "))
        let cast = input.cast.prefix(castLimit)
        out.append("Cast: \(cast.isEmpty ? none : cast.joined(separator: ", "))")

        out.append("")
        out.append("# Lead (Wikipedia: country, language, standing)")
        out.append(section(input.lead))

        out.append("")
        out.append("# Overview (Jellyfin, spoiler-free)")
        out.append(section(input.overview))

        out.append("")
        out.append("# Plot (Wikipedia, full, contains spoilers)")
        out.append(section(input.plot))

        out.append("")
        out.append("# Reception and acclaim (Wikipedia)")
        out.append(section(input.reception))

        out.append("")
        out.append("# Awards (structured)")
        let won = input.awards.filter { $0.kind == .won }.map(line(for:))
        let nominated = input.awards.filter { $0.kind == .nominated }.map(line(for:))
        out.append("Won: \(won.isEmpty ? none : won.joined(separator: "; "))")
        out.append("Nominated: \(nominated.isEmpty ? none : nominated.joined(separator: "; "))")
        out.append("OMDb: \(section(input.omdbAwards))")

        let body = out.joined(separator: "\n")
        let hash = sha256Hex(body)

        var sourceParts: [String] = []
        switch input.source {
        case .wikipedia, .wikipediaOtherLang:
            let lang = input.pageSite.map { WikipediaClient.language(forSite: $0) } ?? "?"
            sourceParts.append("Page: \(input.pageTitle ?? none) (\(lang))")
        case .model:
            sourceParts.append("Page: \(none)")
            sourceParts.append("model-written")
        case .none:
            sourceParts.append("Page: \(none)")
            sourceParts.append("no story source")
        }
        sourceParts.append("fetched \(input.fetchedOn)")
        sourceParts.append(input.unverified ? "unverified" : "verified")
        let block = body + "\n\n# Source\n" + sourceParts.joined(separator: " · ") + "\n"
        return (block, hash)
    }

    static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func section(_ text: String?) -> String {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return none }
        return t
    }

    private static func line(for award: Award) -> String {
        if let year = award.year { return "\(award.name) (\(year))" }
        return award.name
    }
}
