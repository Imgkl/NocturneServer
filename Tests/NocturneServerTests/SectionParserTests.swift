import Foundation
import Testing

@testable import NocturneServer

@Suite struct SectionParserTests {

    private func extract(_ name: String) throws -> String {
        let data = try fixtureData("wikipedia/\(name).json")
        let decoded = try JSONDecoder().decode(WikipediaClient.ExtractsResponse.self, from: data)
        return try #require(decoded.query?.pages?.values.first?.extract)
    }

    @Test func heatHasFullPlotAndReception() throws {
        let article = SectionParser.parse(try extract("heat-1995-film"))
        #expect(!article.isDisambiguation)
        #expect(article.lead.hasPrefix("Heat is a 1995 American epic crime drama film"))
        #expect(article.sections.first?.heading == "Plot")
        #expect(article.sections.first?.level == 2)

        let plot = try #require(SectionParser.plot(from: article))
        let words = SectionParser.wordCount(plot)
        #expect(words >= 650 && words <= 660)
        #expect(plot.hasPrefix("Neil McCauley, a Los Angeles professional thief"))
        #expect(plot.hasSuffix("Hanna takes McCauley's hand as he dies of his wounds."))

        let reception = try #require(SectionParser.reception(from: article))
        #expect(SectionParser.wordCount(reception) > 100)
        #expect(SectionParser.wordCount(reception) <= SectionParser.receptionCapWords)
        // Release is a matching level-2 heading, so its Box office subsection rides along.
        #expect(reception.contains("$"))
    }

    @Test func disambiguationPageHasNoPlot() throws {
        let article = SectionParser.parse(try extract("drive-disambiguation"))
        #expect(article.isDisambiguation)
        #expect(SectionParser.plot(from: article) == nil)
        #expect(SectionParser.reception(from: article) == nil)
    }

    @Test func stubWithoutPlotStillYieldsReception() throws {
        let article = SectionParser.parse(try extract("stub-no-plot"))
        #expect(SectionParser.plot(from: article) == nil)
        let reception = try #require(SectionParser.reception(from: article))
        #expect(SectionParser.wordCount(reception) > 50)
    }

    @Test func tamilHeadingsAreRecognised() throws {
        let article = SectionParser.parse(try extract("ta-nayakan"))
        let plot = try #require(SectionParser.plot(from: article, language: "ta"))
        #expect(SectionParser.wordCount(plot) > 20)
        let reception = try #require(SectionParser.reception(from: article, language: "ta"))
        #expect(SectionParser.wordCount(reception) > 5)
        // English rules must not match Tamil headings by accident.
        #expect(SectionParser.plot(from: article, language: "en") == nil)
    }

    @Test func plotCapKeepsBeginningAndEnding() {
        let words = (1...4_000).map { "w\($0)" }
        let article = ParsedArticle(
            lead: "x", sections: [.init(level: 2, heading: "Plot", body: words.joined(separator: " "))],
            isDisambiguation: false)
        let plot = try! #require(SectionParser.plot(from: article))
        #expect(plot.hasPrefix("w1 w2 w3"))
        #expect(plot.hasSuffix("w3999 w4000"))
        #expect(plot.contains("\n\(SectionParser.cutMarker)\n"))
        let kept = SectionParser.wordCount(plot)
        #expect(kept == SectionParser.plotHeadWords + SectionParser.plotTailWords + 1)
        #expect(!plot.contains(" w1700 "))
    }

    @Test func shortPlotIsNotCut() {
        let article = ParsedArticle(lead: "", sections: [.init(level: 2, heading: "Synopsis", body: "Short story.")], isDisambiguation: false)
        #expect(SectionParser.plot(from: article) == "Short story.")
    }

    @Test func headingVariantsAndSubsections() {
        let text = """
        Lead paragraph.

        == Plot summary ==
        Part one.

        === Act two ===
        Part two.

        == Cast ==
        People.

        == Release ==
        Released in May.

        === Critical response ===
        Critics liked it.

        == Awards and nominations ==
        Won things.

        == Box Office ==
        Made money.
        """
        let article = SectionParser.parse(text)
        #expect(article.lead == "Lead paragraph.")
        #expect(article.sections.map(\.heading) == ["Plot summary", "Act two", "Cast", "Release", "Critical response", "Awards and nominations", "Box Office"])
        #expect(SectionParser.plot(from: article) == "Part one.\n\nPart two.")
        let reception = SectionParser.reception(from: article)
        #expect(reception == "Released in May.\n\nCritics liked it.\n\nWon things.\n\nMade money.")
        #expect(SectionParser.isPlotHeading("Storyline", language: "en"))
        #expect(SectionParser.isPlotHeading("Premise", language: "en"))
        #expect(!SectionParser.isPlotHeading("Plotting the course", language: "en"))
        #expect(!SectionParser.isPlotHeading("Cast", language: "en"))
        #expect(SectionParser.isReceptionHeading("Legacy", language: "en"))
        #expect(!SectionParser.isReceptionHeading("Production", language: "en"))
    }

    @Test func headingLineParsing() {
        #expect(SectionParser.headingParts("== Plot ==")! == (2, "Plot"))
        #expect(SectionParser.headingParts("=== Box office ===")! == (3, "Box office"))
        #expect(SectionParser.headingParts("==Plot==")! == (2, "Plot"))
        #expect(SectionParser.headingParts("= Not a heading =") == nil)
        #expect(SectionParser.headingParts("Plot == twist") == nil)
        #expect(SectionParser.headingParts("== ==") == nil)
    }
}
