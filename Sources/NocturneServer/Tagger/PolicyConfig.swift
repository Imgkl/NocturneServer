import Foundation

/// The policy's knobs, read from settings with the spec's initial values: which version decides,
/// the floor a classifier probability has to clear per mood, and the "high" line above which a
/// mood the reader never named still becomes a suggestion.
struct PolicyConfig: Sendable, Equatable {
    static let versionSetting = "policy.version"
    static let floorsSetting = "policy.floors"
    static let highSetting = "policy.high"
    static let providerSetting = "classifier.provider"

    static let defaultVersion = PolicyEngine.p1Version
    static let defaultFloor = 0.70
    static let defaultHigh = 0.85
    /// Moods that carried a stricter floor before the classifier existed keep one.
    static let strictMoods: Set<String> = ["crime-grit-style", "slow-burn-sharp-blade", "ha-ha-ha", "film-school-shelf", "regional-gems", "bittersweet-aftermath"]
    static let strictFloor = 0.80

    enum Provider: String, Sendable {
        case none
        case jev
    }

    let version: String
    let provider: Provider
    let floors: [String: Double]
    let high: [String: Double]

    static func defaults(slugs: some Sequence<String>) -> PolicyConfig {
        var floors: [String: Double] = [:]
        var high: [String: Double] = [:]
        for slug in slugs {
            floors[slug] = strictMoods.contains(slug) ? strictFloor : defaultFloor
            high[slug] = defaultHigh
        }
        return PolicyConfig(version: defaultVersion, provider: .none, floors: floors, high: high)
    }

    /// Settings override the defaults mood by mood; unknown moods in a stored table are ignored.
    static func load(settings: SettingsStore, slugs: some Sequence<String>) async throws -> PolicyConfig {
        let known = Set(slugs)
        let base = defaults(slugs: known)
        var floors = base.floors
        var high = base.high
        if let stored = try await settings.get(floorsSetting), let table = Self.decode(stored) {
            for (slug, value) in table where known.contains(slug) { floors[slug] = min(1, max(0, value)) }
        }
        if let stored = try await settings.get(highSetting), let table = Self.decode(stored) {
            for (slug, value) in table where known.contains(slug) { high[slug] = min(1, max(0, value)) }
        }
        let version = try await settings.get(versionSetting).flatMap { PolicyEngine.versions.contains($0) ? $0 : nil } ?? defaultVersion
        let provider = try await settings.get(providerSetting).flatMap(Provider.init(rawValue:)) ?? .none
        return PolicyConfig(version: version, provider: provider, floors: floors, high: high)
    }

    static func decode(_ json: String) -> [String: Double]? {
        try? JSONDecoder().decode([String: Double].self, from: Data(json.utf8))
    }

    static func encode(_ table: [String: Double]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(table)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
