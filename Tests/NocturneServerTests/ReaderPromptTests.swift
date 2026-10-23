import Foundation
import Testing

@testable import NocturneServer

@Suite struct ReaderPromptTests {
    private let config = NocturneConfiguration()

    @Test func systemBlockIsStaticAndClean() {
        let a = ReaderPrompt.systemBlock(rules: config.autoTaggingPrompt, buckets: config.moodBuckets)
        let b = ReaderPrompt.systemBlock(rules: config.autoTaggingPrompt, buckets: config.moodBuckets)
        #expect(a == b)
        #expect(!a.contains("Min confidence"))
        #expect(!a.contains("Recent user decisions"))
        #expect(!a.contains("Rule 8"))
        #expect(a.contains("Rule 7: Valid slugs and the admin's calibration"))
        #expect(a.contains("Rule 0: Residue first"))
        #expect(a.contains("antihero-study: Antihero Study"))
        #expect(a.contains("  Qualifies when:\n    - "))
        #expect(a.contains("  Text cues: "))
        #expect(a.contains("Does NOT fit:"))
        #expect(!a.contains("Keywords:"))
        // Sorted by slug: the first entry after the rules is the alphabetically first bucket.
        let firstEntry = a.range(of: "Available mood tags:\n\n").map { a[$0.upperBound...].prefix(40) }
        #expect(firstEntry?.hasPrefix("antihero-study:") == true)
        // Roughly the size the spec expects for the cached prefix.
        let words = a.split(whereSeparator: { $0.isWhitespace }).count
        #expect(words > 6_000 && words < 12_000)
    }

    @Test func rulesNoLongerMentionMinConfidence() {
        #expect(!config.autoTaggingPrompt.contains("Min confidence"))
        #expect(config.autoTaggingPrompt.contains("Apply Rules 1 to 7"))
    }

    @Test func userTurnOrderAndCalibrationCaps() {
        let calibration: [String: TagCalibration] = [
            "ha-ha-ha": TagCalibration(positives: ["A", "B", "C", "D", "E", "F", "G"], negatives: ["X", "Y", "Z", "W"]),
            "cult-chaos": TagCalibration(positives: [], negatives: ["Q"]),
            "quiet-epics": TagCalibration(),
        ]
        let turn = ReaderPrompt.userTurn(learnedRules: "Topic beats kind.", calibration: calibration, textBlock: "# Identity\nTitle: Heat (1995)", maxTags: 5)
        #expect(turn.contains("a short quote from the Film text, a colon, then the condition it satisfies"))
        #expect(turn.contains("up to 3 alternates you considered and set aside"))
        let learned = turn.range(of: "## Learned from you\nThe owner's rules. Each overrides the named mood's Qualifies when and Does NOT fit lines when they conflict; name that mood when a rule holds.\nTopic beats kind.")!
        let decisions = turn.range(of: "## Your recent decisions")!
        let film = turn.range(of: "## Film\n# Identity")!
        let task = turn.range(of: "## Task")!
        #expect(learned.lowerBound < decisions.lowerBound)
        #expect(decisions.lowerBound < film.lowerBound)
        #expect(film.lowerBound < task.lowerBound)
        #expect(turn.contains("cult-chaos: rejected on Q"))
        #expect(turn.contains("ha-ha-ha: confirmed on A, B, C, D, E; rejected on X, Y, Z"))
        #expect(!turn.contains("F, G"))
        #expect(!turn.contains("quiet-epics"))
        #expect(turn.contains("every mood that plausibly fits the whole film (2 to 4 is typical, at most 5)"))
        #expect(turn.contains("Never mention events after the first act"))
    }

    @Test func emptyLearnedAndCalibrationRenderAsNone() {
        let turn = ReaderPrompt.userTurn(learnedRules: nil, calibration: [:], textBlock: "x", maxTags: 3)
        #expect(turn.contains("## Learned from you\nThe owner's rules. Each overrides the named mood's Qualifies when and Does NOT fit lines when they conflict; name that mood when a rule holds.\n(none)"))
        #expect(turn.contains("## Your recent decisions\n(none)"))
    }
}
