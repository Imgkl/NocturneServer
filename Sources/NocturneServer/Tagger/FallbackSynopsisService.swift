import Foundation
import Logging

struct SynopsisResult: Codable, Sendable, Equatable {
    let plot: String
    let reception: String
    let sources: [String]
}

enum SynopsisError: Error, CustomStringConvertible {
    case incomplete(stopReason: String)
    case malformed(String)

    var description: String {
        switch self {
        case .incomplete(let reason): return "synopsis stopped early (\(reason))"
        case .malformed(let detail): return "synopsis returned unusable JSON: \(detail)"
        }
    }
}

/// The only place a model writes story text: a strong model with web search, for films that
/// have no plot on any Wikipedia. Off by default; the admin can switch it on for the coverage
/// long tail or trigger it per film. Output is always stored as `unverified`.
final class FallbackSynopsisService: SynopsisWriting, Sendable {
    static let modelSetting = "models.strong"
    static let defaultModel = "claude-opus-5-5"
    static let enabledSetting = "enrichment.model_fallback"
    static let maxTokens = 8_192
    static let maxSearches = 5

    let anthropic: AnthropicClient
    let settings: SettingsStore
    let logger: Logger

    init(anthropic: AnthropicClient, settings: SettingsStore, logger: Logger = Logger(label: "Synopsis")) {
        self.anthropic = anthropic
        self.settings = settings
        self.logger = logger
    }

    func model() async throws -> String {
        if let configured = try await settings.get(Self.modelSetting)?.trimmingCharacters(in: .whitespaces), !configured.isEmpty {
            return configured
        }
        return Self.defaultModel
    }

    func isEnabled() async throws -> Bool {
        (try await settings.get(Self.enabledSetting))?.lowercased() == "on"
    }

    func write(for identity: EnrichmentService.Identity, apiKey: String, context: CallContext = .none) async throws -> SynopsisResult {
        let model = try await model()
        let body = try Self.requestBody(model: model, identity: identity)
        let response = try await anthropic.messages(apiKey: apiKey, model: model, body: body, timeout: .seconds(180), context: context)
        if let stop = response.stopReason, stop != "end_turn" {
            throw SynopsisError.incomplete(stopReason: stop)
        }
        let result = try Self.parse(response)
        logger.info("synopsis \(model): \(SectionParser.wordCount(result.plot)) plot words, \(result.sources.count) sources, \(response.usage?.serverToolUse?.webSearchRequests ?? 0) searches")
        return result
    }

    static func prompt(for identity: EnrichmentService.Identity) -> String {
        var lines: [String] = []
        lines.append("Write the complete plot of this film, including the ending, then one paragraph on its critical reception and any awards or festival history. Use web search to confirm the facts and list the sources you relied on. Write plainly; no headings inside the fields.")
        lines.append("")
        lines.append("Title: \(identity.title)\(identity.year.map { " (\($0))" } ?? "")")
        if let original = identity.originalTitle, original != identity.title { lines.append("Original title: \(original)") }
        if let director = identity.director { lines.append("Director: \(director)") }
        if !identity.genres.isEmpty { lines.append("Genres: \(identity.genres.joined(separator: ", "))") }
        if !identity.cast.isEmpty { lines.append("Cast: \(identity.cast.joined(separator: ", "))") }
        if let imdb = identity.imdbId { lines.append("IMDb id: \(imdb)") }
        if let overview = identity.overview, !overview.isEmpty { lines.append("Catalogue overview: \(overview)") }
        return lines.joined(separator: "\n")
    }

    static var outputSchema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["plot", "reception", "sources"],
            "properties": [
                "plot": ["type": "string"],
                "reception": ["type": "string"],
                "sources": ["type": "array", "items": ["type": "string"]],
            ],
        ]
    }

    static func requestBody(model: String, identity: EnrichmentService.Identity) throws -> Data {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "tools": [["type": "web_search_20260209", "name": "web_search", "max_uses": maxSearches]],
            "messages": [
                ["role": "user", "content": [["type": "text", "text": prompt(for: identity)]]]
            ],
            "output_config": [
                "effort": "medium",
                "format": ["type": "json_schema", "schema": outputSchema],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// The structured answer is the last text block; earlier text blocks (if any) are the model
    /// narrating its searches.
    static func parse(_ response: AnthropicMessageResponse) throws -> SynopsisResult {
        let texts = response.content.compactMap { $0.type == "text" ? $0.text : nil }
        for text in texts.reversed() {
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = cleaned.data(using: .utf8), let result = try? JSONDecoder().decode(SynopsisResult.self, from: data) else { continue }
            guard !result.plot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SynopsisError.malformed("empty plot")
            }
            return result
        }
        throw SynopsisError.malformed("no JSON text block in response")
    }
}
