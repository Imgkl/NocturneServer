import Foundation

/// Assembles the reader's two prompt halves. The system block is static (rules plus every
/// bucket definition) and identical for every film, so it is cached across calls. The user
/// turn carries everything that changes: learned rules, calibration, the film's text block.
enum ReaderPrompt {
    static let version = 1

    /// Rules and bucket definitions, nothing per film, nothing per session. Sorted by slug so the
    /// bytes never move between calls.
    static func systemBlock(rules: String, buckets: [String: MoodBucket]) -> String {
        var out: [String] = []
        out.append(rules.trimmingCharacters(in: .whitespacesAndNewlines))
        out.append("")
        out.append("Available mood tags:")
        out.append("")
        for slug in buckets.keys.sorted() {
            guard let bucket = buckets[slug] else { continue }
            var entry = "\(slug): \(bucket.title)\n  Residue: \(bucket.description.trimmingCharacters(in: .whitespacesAndNewlines))"
            if let qualifies = bucket.qualifies, !qualifies.isEmpty {
                entry += "\n  Qualifies when:\n    - " + qualifies.joined(separator: "\n    - ")
            }
            if let cues = bucket.cues, !cues.isEmpty {
                entry += "\n  Text cues: \(cues.joined(separator: "; "))"
            }
            if let keywords = bucket.tags, !keywords.isEmpty {
                entry += "\n  Keywords: \(keywords.joined(separator: ", "))"
            }
            if let fits = bucket.anchorsFit, !fits.isEmpty {
                entry += "\n  Fits:\n    - " + fits.joined(separator: "\n    - ")
            }
            if let misses = bucket.anchorsMiss, !misses.isEmpty {
                entry += "\n  Does NOT fit:\n    - " + misses.joined(separator: "\n    - ")
            }
            out.append(entry)
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    /// Learned rules first, then the admin's recent decisions, then the film, then the task.
    static func userTurn(
        learnedRules: String?, calibration: [String: TagCalibration], textBlock: String, maxTags: Int,
        maxPositives: Int = 5, maxNegatives: Int = 3
    ) -> String {
        var out: [String] = []
        out.append("## Learned from you")
        let learned = learnedRules?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        out.append(learned.isEmpty ? "(none)" : learned)
        out.append("")

        out.append("## Your recent decisions")
        let lines = calibration.keys.sorted().compactMap { slug -> String? in
            guard let cal = calibration[slug] else { return nil }
            let positives = cal.positives.prefix(maxPositives)
            let negatives = cal.negatives.prefix(maxNegatives)
            guard !positives.isEmpty || !negatives.isEmpty else { return nil }
            var parts: [String] = []
            if !positives.isEmpty { parts.append("confirmed on \(positives.joined(separator: ", "))") }
            if !negatives.isEmpty { parts.append("rejected on \(negatives.joined(separator: ", "))") }
            return "\(slug): \(parts.joined(separator: "; "))"
        }
        out.append(lines.isEmpty ? "(none)" : lines.joined(separator: "\n"))
        out.append("")

        out.append("## Film")
        out.append(textBlock.trimmingCharacters(in: .whitespacesAndNewlines))
        out.append("")

        out.append("## Task")
        out.append(
            "State the residue in one sentence, then list every mood that plausibly fits the whole film (2 to 4 is typical, at most \(maxTags)), "
                + "each with evidence (a short quote from the Film text, a colon, then the condition it satisfies) and "
                + "a confidence in [0, 1] on the Rule 6 scale, then up to 3 alternates you considered and set aside. "
                + "Use only slugs from the available mood tags. Never mention events after the first act "
                + "in the residue sentence.")
        return out.joined(separator: "\n")
    }

    /// Structured output schema for the reader. Every object closes `additionalProperties`.
    static var outputSchema: [String: Any] {
        [
        "type": "object",
        "additionalProperties": false,
        "required": ["residue", "candidates", "alternates"],
        "properties": [
            "residue": [
                "type": "string",
                "description": "One sentence: the feeling the viewer carries home. No events after the first act.",
            ],
            "candidates": [
                "type": "array",
                "description": "Every mood that plausibly fits the whole film, strongest first. Two to four is typical; one is an error unless the film truly fits only one mood; at most 5.",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["slug", "evidence", "confidence"],
                    "properties": [
                        "slug": ["type": "string", "description": "A slug from the available mood tags, nothing invented."],
                        "evidence": [
                            "type": "string",
                            "description": "A short quote from the Film text, a colon, then the Qualifies-when condition it satisfies. Under 30 words. A plot event on its own is not evidence.",
                        ],
                        "confidence": ["type": "number", "description": "0 to 1 on the guide's Rule 6 scale: 0.80 and above only when every condition of the bucket holds."],
                    ],
                ],
            ],
            "alternates": [
                "type": "array",
                "description": "Up to 3 slugs you considered and set aside because a condition fails.",
                "items": ["type": "string"],
            ],
        ],
        ]
    }
}
