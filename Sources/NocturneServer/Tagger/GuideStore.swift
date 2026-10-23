import Foundation

/// The owner's guide as the models read it: the manual rules (seeded from `Resources/guide.md`,
/// editable in Settings) and the rules learned from Teach, with a version that re-grades can
/// key off.
enum GuideStore {
    static let manualSetting = "guide.manual"
    static let learnedSetting = "guide.learned"
    static let versionSetting = "guide.version"

    struct LearnedRule: Codable, Sendable, Equatable {
        /// `slugA|slugB`, the boundary the rule sharpens.
        let boundary: String
        let text: String
        let acceptedAt: Date
    }

    /// The manual guide: the setting when the owner edited it, else the bundled text.
    static func manual(settings: SettingsStore, fallback: String) async throws -> String {
        if let stored = try await settings.get(manualSetting)?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty {
            return stored
        }
        return fallback
    }

    static func learned(settings: SettingsStore) async throws -> [LearnedRule] {
        guard let json = try await settings.get(learnedSetting), !json.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([LearnedRule].self, from: Data(json.utf8))) ?? []
    }

    /// The learned rules as the prompt's "Learned from you" block, nil when there are none.
    /// Each learned rule filed under the mood it is about: the boundary slugs the rule text names,
    /// or both boundary slugs when it names neither. The classifier and the reader read a rule next
    /// to that mood's own conditions, where it can override them.
    static func rulesByMood(_ rules: [LearnedRule]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for rule in rules {
            let slugs = rule.boundary.split(separator: "|").map(String.init)
            let named = slugs.filter { rule.text.contains($0) }
            for slug in (named.isEmpty ? slugs : named) { out[slug, default: []].append(rule.text) }
        }
        return out
    }

    static func rulesByMood(settings: SettingsStore) async throws -> [String: [String]] {
        rulesByMood(try await learned(settings: settings))
    }

    /// The reader's copy: one line per rule, led by the mood it overrides.
    static func readerText(_ rules: [LearnedRule]) -> String? {
        let byMood = rulesByMood(rules)
        guard !byMood.isEmpty else { return nil }
        return byMood.keys.sorted().flatMap { slug in byMood[slug]!.map { "- \(slug): \($0)" } }.joined(separator: "\n")
    }

    static func learnedText(settings: SettingsStore) async throws -> String? {
        let rules = try await learned(settings: settings)
        guard !rules.isEmpty else { return nil }
        return rules.map { "- \($0.text)" }.joined(separator: "\n")
    }

    /// Manual rules followed by the learned ones: what the classifier reads.
    static func full(settings: SettingsStore, fallback: String) async throws -> String {
        var text = try await manual(settings: settings, fallback: fallback)
        if let learned = try await learnedText(settings: settings) {
            text += "\n\nLearned from the owner's own decisions (these win over the mood descriptions):\n" + learned
        }
        return text
    }

    static func version(settings: SettingsStore) async throws -> Int {
        Int(try await settings.get(versionSetting) ?? "") ?? 1
    }

    static func setManual(_ text: String, settings: SettingsStore) async throws -> Int {
        try await settings.set(manualSetting, text.trimmingCharacters(in: .whitespacesAndNewlines))
        return try await bump(settings: settings)
    }

    static func setLearned(_ rules: [LearnedRule], settings: SettingsStore) async throws -> Int {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(rules)
        try await settings.set(learnedSetting, String(decoding: data, as: UTF8.self))
        return try await bump(settings: settings)
    }

    private static func bump(settings: SettingsStore) async throws -> Int {
        let next = try await version(settings: settings) + 1
        try await settings.set(versionSetting, String(next))
        return next
    }
}
