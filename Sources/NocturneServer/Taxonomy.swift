import Foundation
import Logging

enum ResourceError: Error, CustomStringConvertible {
    case missing(String)
    case invalid(String)

    var description: String {
        switch self {
        case .missing(let name): return "resource missing: \(name)"
        case .invalid(let detail): return "resource invalid: \(detail)"
        }
    }
}

/// The 36 mood buckets, loaded from `Resources/taxonomy.json`. Editable by hand; `version` is
/// stamped on every decision so replays know which taxonomy produced them.
struct Taxonomy: Sendable {
    let version: Int
    let buckets: [String: MoodBucket]

    private struct File: Decodable {
        let version: Int
        let buckets: [String: MoodBucket]
    }

    static func load(bundle: Bundle = .module) throws -> Taxonomy {
        // `.copy("Resources")` keeps the directory, so the files live under `Resources/` in the bundle.
        guard let url = bundle.url(forResource: "taxonomy", withExtension: "json", subdirectory: "Resources") else {
            throw ResourceError.missing("Resources/taxonomy.json")
        }
        return try load(from: url)
    }

    static func load(from url: URL) throws -> Taxonomy {
        let data = try Data(contentsOf: url)
        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: data)
        } catch {
            throw ResourceError.invalid("taxonomy.json does not decode: \(error)")
        }
        guard file.version >= 1 else { throw ResourceError.invalid("taxonomy version must be at least 1") }
        guard !file.buckets.isEmpty else { throw ResourceError.invalid("taxonomy has no buckets") }
        for (slug, bucket) in file.buckets {
            guard slug.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil else {
                throw ResourceError.invalid("bucket slug \"\(slug)\" is not lowercase-dashed")
            }
            guard !bucket.title.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ResourceError.invalid("bucket \(slug) has no title")
            }
            guard !bucket.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ResourceError.invalid("bucket \(slug) has no description")
            }
            if let floor = bucket.minConfidence, !(0...1).contains(floor) {
                throw ResourceError.invalid("bucket \(slug) minConfidence \(floor) is outside [0, 1]")
            }
        }
        return Taxonomy(version: file.version, buckets: file.buckets)
    }
}

/// The admin's filing guide, loaded from `Resources/guide.md`. Phase 4 seeds the editable
/// `guide.manual` setting from it and appends the learned rules.
enum Guide {
    static func loadManual(bundle: Bundle = .module) throws -> String {
        guard let url = bundle.url(forResource: "guide", withExtension: "md", subdirectory: "Resources") else {
            throw ResourceError.missing("Resources/guide.md")
        }
        return try load(from: url)
    }

    static func load(from url: URL) throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ResourceError.invalid("guide.md is empty") }
        return text
    }
}
