import Foundation
import Testing

@testable import NocturneServer

@Suite struct TextBlockBuilderTests {

    private var heat: TextBlockInput {
        TextBlockInput(
            title: "Heat", originalTitle: "Heat", year: 1995, director: "Michael Mann", runtimeMinutes: 170,
            genres: ["Crime", "Drama", "Thriller"],
            cast: ["Al Pacino", "Robert De Niro", "Val Kilmer", "Jon Voight", "Tom Sizemore", "Diane Venora"],
            overview: "Obsessive master thief Neil McCauley leads a top-notch crew.",
            lead: "Heat is a 1995 American epic crime drama film written and directed by Michael Mann.",
            plot: "Neil McCauley robs an armored car. ... Hanna takes McCauley's hand as he dies of his wounds.",
            reception: "Critics praised the shootout.",
            awards: [Award(name: "Saturn Award", kind: .nominated, year: 1996)],
            omdbAwards: "Nominated for 1 BAFTA Award. 12 wins & 15 nominations total",
            pageTitle: "Heat (1995 film)", pageSite: "enwiki", fetchedOn: "2026-10-21", source: .wikipedia, unverified: false)
    }

    @Test func goldenBlockForHeat() {
        let (block, _) = TextBlockBuilder.build(heat)
        let expected = """
        # Identity
        Title: Heat (1995)
        Director: Michael Mann · Runtime: 170 min · Genres: Crime, Drama, Thriller
        Cast: Al Pacino, Robert De Niro, Val Kilmer, Jon Voight, Tom Sizemore

        # Lead (Wikipedia: country, language, standing)
        Heat is a 1995 American epic crime drama film written and directed by Michael Mann.

        # Overview (Jellyfin, spoiler-free)
        Obsessive master thief Neil McCauley leads a top-notch crew.

        # Plot (Wikipedia, full, contains spoilers)
        Neil McCauley robs an armored car. ... Hanna takes McCauley's hand as he dies of his wounds.

        # Reception and acclaim (Wikipedia)
        Critics praised the shootout.

        # Awards (structured)
        Won: (none)
        Nominated: Saturn Award (1996)
        OMDb: Nominated for 1 BAFTA Award. 12 wins & 15 nominations total

        # Source
        Page: Heat (1995 film) (en) · fetched 2026-10-21 · verified

        """
        #expect(block == expected)
    }

    @Test func missingSectionsRenderAsNoneAndSourceLineVaries() {
        var input = TextBlockInput(title: "Obscure", fetchedOn: "2026-10-21")
        let (none, _) = TextBlockBuilder.build(input)
        #expect(none.contains("# Lead (Wikipedia: country, language, standing)\n(none)"))
        #expect(none.contains("# Overview (Jellyfin, spoiler-free)\n(none)"))
        #expect(none.contains("# Plot (Wikipedia, full, contains spoilers)\n(none)"))
        #expect(none.contains("Won: (none)\nNominated: (none)\nOMDb: (none)"))
        #expect(none.contains("Cast: (none)"))
        #expect(none.hasSuffix("# Source\nPage: (none) · no story source · fetched 2026-10-21 · verified\n"))

        input.source = .model
        input.unverified = true
        let (model, _) = TextBlockBuilder.build(input)
        #expect(model.hasSuffix("Page: (none) · model-written · fetched 2026-10-21 · unverified\n"))

        input.source = .wikipediaOtherLang
        input.unverified = false
        input.pageSite = "tawiki"
        input.pageTitle = "நாயகன்"
        let (ta, _) = TextBlockBuilder.build(input)
        #expect(ta.hasSuffix("Page: நாயகன் (ta) · fetched 2026-10-21 · verified\n"))
    }

    @Test func hashIsStableAndIgnoresTheSourceLine() {
        let (_, a) = TextBlockBuilder.build(heat)
        let (_, b) = TextBlockBuilder.build(heat)
        #expect(a == b)
        #expect(a.count == 64)
        #expect(a == TextBlockBuilder.sha256Hex(String(TextBlockBuilder.build(heat).block.split(separator: "\n\n# Source\n").first!)))

        var later = heat
        later.fetchedOn = "2027-01-01"
        #expect(TextBlockBuilder.build(later).hash == a)

        var changed = heat
        changed.cast[0] = "Al Pacino Jr."
        #expect(TextBlockBuilder.build(changed).hash != a)
    }

    @Test func identityLineOmitsRedundantOriginalTitleAndCapsCast() {
        var input = heat
        input.originalTitle = "Heat"
        #expect(!TextBlockBuilder.build(input).block.contains("Original title"))
        input.originalTitle = "Chaleur"
        #expect(TextBlockBuilder.build(input).block.contains("Title: Heat (1995) · Original title: Chaleur"))
        #expect(!TextBlockBuilder.build(input).block.contains("Diane Venora"))
        input.director = nil
        input.runtimeMinutes = nil
        input.genres = []
        #expect(TextBlockBuilder.build(input).block.contains("Title: Heat (1995) · Original title: Chaleur\n(none)\nCast:"))
    }

    @Test func blockNeverCarriesPromptArtifacts() {
        let (block, _) = TextBlockBuilder.build(heat)
        #expect(!block.contains("Min confidence"))
        #expect(!block.contains("Recent user decisions"))
    }
}
