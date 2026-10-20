import Foundation

/// A Wikipedia plain-text extract (`prop=extracts&explaintext=1&exsectionformat=wiki`) split
/// into its lead paragraph and headed sections.
struct ParsedArticle: Sendable, Equatable {
    struct Section: Sendable, Equatable {
        let level: Int
        let heading: String
        let body: String
    }

    let lead: String
    let sections: [Section]
    let isDisambiguation: Bool
}

enum SectionParser {
    static let plotCapWords = 2_500
    static let plotHeadWords = 1_500
    static let plotTailWords = 1_000
    static let receptionCapWords = 800
    static let cutMarker = "[...]"

    /// English heading forms for the story. Anchored at the start of the heading.
    private static let englishPlot = try! NSRegularExpression(
        pattern: #"^(plot|synopsis|story(line)?|premise)\b"#, options: [.caseInsensitive])
    /// English heading forms for reception, acclaim and release. Matched anywhere in the heading.
    private static let englishReception = try! NSRegularExpression(
        pattern: #"(reception|critical|accolades|awards|legacy|release|box office|response)"#, options: [.caseInsensitive])

    /// Heading spellings on the other-language wikis enrichment falls back to. Tamil entries
    /// come from the captured Nayakan page; the rest are the common forms and get extended
    /// as the coverage run shows what real pages use.
    static let plotHeadings: [String: Set<String>] = [
        "ta": ["கதை", "கதைச்சுருக்கம்", "கதைக்களம்", "கதைச் சுருக்கம்"],
        "ml": ["കഥാസംഗ്രഹം", "കഥ", "ഇതിവൃത്തം", "കഥാസാരം"],
        "hi": ["कथानक", "कहानी", "कथा", "संक्षेप"],
        "kn": ["ಕಥಾವಸ್ತು", "ಕಥೆ", "ಕಥಾ ಸಾರಾಂಶ"],
        "te": ["కథ", "కథాంశం", "కథా సంగ్రహం"],
        "bn": ["কাহিনি", "কাহিনী", "কাহিনী সংক্ষেপ", "কাহিনিসংক্ষেপ"],
    ]
    static let receptionHeadings: [String: Set<String>] = [
        "ta": ["விருதுகள்", "வரவேற்பு", "விமர்சனம்", "விமர்சனங்கள்", "வெளியீடும் விமர்சனமும்", "வெளியீடு"],
        "ml": ["പുരസ്കാരങ്ങൾ", "അവലോകനം", "നിരൂപണം", "പ്രതികരണം", "സ്വീകരണം"],
        "hi": ["पुरस्कार", "समीक्षा", "समीक्षाएँ", "प्रतिक्रिया", "सम्मान"],
        "kn": ["ಪ್ರಶಸ್ತಿಗಳು", "ವಿಮರ್ಶೆ", "ಪ್ರತಿಕ್ರಿಯೆ"],
        "te": ["పురస్కారాలు", "స్పందన", "విమర్శలు", "అవార్డులు"],
        "bn": ["পুরস্কার", "সমালোচনা", "প্রতিক্রিয়া", "মূল্যায়ন"],
    ]

    // MARK: Parsing

    static func parse(_ extract: String) -> ParsedArticle {
        var lead: [String] = []
        var sections: [ParsedArticle.Section] = []
        var current: (level: Int, heading: String, lines: [String])? = nil

        for rawLine in extract.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let (level, heading) = headingParts(line) {
                if let c = current {
                    sections.append(.init(level: c.level, heading: c.heading, body: trimmed(c.lines)))
                }
                current = (level, heading, [])
            } else if current != nil {
                current!.lines.append(line)
            } else {
                lead.append(line)
            }
        }
        if let c = current {
            sections.append(.init(level: c.level, heading: c.heading, body: trimmed(c.lines)))
        }

        let leadText = trimmed(lead)
        let firstLine = leadText.split(separator: "\n").first.map(String.init) ?? ""
        let isDisambiguation = firstLine.lowercased().contains("may refer to")
        return ParsedArticle(lead: leadText, sections: sections, isDisambiguation: isDisambiguation)
    }

    /// `== Plot ==` to (2, "Plot"); anything else to nil.
    static func headingParts(_ line: String) -> (Int, String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("==") else { return nil }
        var level = 0
        var idx = t.startIndex
        while idx < t.endIndex, t[idx] == "=" { level += 1; idx = t.index(after: idx) }
        guard level >= 2, t.hasSuffix(String(repeating: "=", count: level)) else { return nil }
        let inner = t.dropFirst(level).dropLast(level).trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return nil }
        return (level, inner)
    }

    // MARK: Selection

    /// The story section with its subsections, capped to `plotCapWords` keeping the beginning
    /// and the ending. Nil when the page has no recognisable story section.
    static func plot(from article: ParsedArticle, language: String = "en", capWords: Int = plotCapWords) -> String? {
        guard !article.isDisambiguation else { return nil }
        guard let start = article.sections.firstIndex(where: { isPlotHeading($0.heading, language: language) }) else {
            return nil
        }
        let level = article.sections[start].level
        var parts: [String] = []
        for section in article.sections[start...] {
            if section != article.sections[start], section.level <= level { break }
            if !section.body.isEmpty { parts.append(section.body) }
        }
        let text = parts.joined(separator: "\n\n")
        guard !text.isEmpty else { return nil }
        return capped(text, maxWords: capWords, head: plotHeadWords, tail: plotTailWords)
    }

    /// Every reception, acclaim, awards and release section in document order, capped to
    /// `receptionCapWords` from the start. Nil when none exist.
    static func reception(from article: ParsedArticle, language: String = "en", capWords: Int = receptionCapWords) -> String? {
        guard !article.isDisambiguation else { return nil }
        var included = Set<Int>()
        var parts: [String] = []
        for (i, section) in article.sections.enumerated() where !included.contains(i) {
            guard isReceptionHeading(section.heading, language: language) else { continue }
            included.insert(i)
            if !section.body.isEmpty { parts.append(section.body) }
            // Subsections of a matching section come along with it.
            var j = i + 1
            while j < article.sections.count, article.sections[j].level > section.level {
                included.insert(j)
                if !article.sections[j].body.isEmpty { parts.append(article.sections[j].body) }
                j += 1
            }
        }
        let text = parts.joined(separator: "\n\n")
        guard !text.isEmpty else { return nil }
        return capped(text, maxWords: capWords, head: capWords, tail: 0)
    }

    static func isPlotHeading(_ heading: String, language: String) -> Bool {
        if language == "en" {
            return matches(englishPlot, heading)
        }
        let h = heading.trimmingCharacters(in: .whitespaces)
        return plotHeadings[language]?.contains(h) ?? false
    }

    static func isReceptionHeading(_ heading: String, language: String) -> Bool {
        if language == "en" {
            return matches(englishReception, heading)
        }
        let h = heading.trimmingCharacters(in: .whitespaces)
        return receptionHeadings[language]?.contains(h) ?? false
    }

    // MARK: Helpers

    /// Keeps the first `head` and last `tail` words when `text` exceeds `maxWords`, joined by
    /// the cut marker on its own line. Otherwise returns `text` unchanged.
    static func capped(_ text: String, maxWords: Int, head: Int, tail: Int) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        guard words.count > maxWords else { return text }
        let headWords = words.prefix(head).joined(separator: " ")
        guard tail > 0 else { return headWords }
        let tailWords = words.suffix(tail).joined(separator: " ")
        return "\(headWords)\n\(cutMarker)\n\(tailWords)"
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func trimmed(_ lines: [String]) -> String {
        lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
