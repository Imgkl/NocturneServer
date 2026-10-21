import Foundation
import Logging

// MARK: - Answer types

struct ReaderCandidate: Codable, Sendable, Equatable {
    let slug: String
    let evidence: String
    /// Kept for the phase 1 bridge policy only; the classifier owns probabilities from phase 2.
    let confidence: Double
}

struct ReaderAnswer: Codable, Sendable, Equatable {
    let residue: String
    let candidates: [ReaderCandidate]
    let alternates: [String]
}

struct ReaderResult: Sendable {
    let answer: ReaderAnswer
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let rawJson: String
}

enum ReaderError: Error, CustomStringConvertible {
    case incomplete(stopReason: String)
    case malformed(String)

    var description: String {
        switch self {
        case .incomplete(let reason): return "reader stopped early (\(reason))"
        case .malformed(let detail): return "reader returned unusable JSON: \(detail)"
        }
    }
}

// MARK: - Service

/// One Messages API call per film: cached static system block, structured JSON output,
/// settings-selectable model. Its confidence numbers are not the classifier's probabilities.
final class ReaderService: Sendable {
    static let modelSetting = "models.reader"
    static let defaultModel = "claude-haiku-5-5"
    static let maxTokens = 4096

    let anthropic: AnthropicClient
    let settings: SettingsStore
    /// The system block for the bundled guide; an edited guide is rendered per call.
    let systemBlock: String
    let fallbackRules: String
    let buckets: [String: MoodBucket]
    let knownSlugs: Set<String>
    let maxTags: Int
    let logger: Logger
    let environment: [String: String]

    init(
        anthropic: AnthropicClient, settings: SettingsStore, buckets: [String: MoodBucket], rules: String,
        maxTags: Int, logger: Logger = Logger(label: "Reader"),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.anthropic = anthropic
        self.settings = settings
        self.systemBlock = ReaderPrompt.systemBlock(rules: rules, buckets: buckets)
        self.fallbackRules = rules
        self.buckets = buckets
        self.knownSlugs = Set(buckets.keys)
        self.maxTags = maxTags
        self.logger = logger
        self.environment = environment
    }

    /// The reader model: the setting, else the legacy env var, else the default.
    func model() async throws -> String {
        if let configured = try await settings.get(Self.modelSetting)?.trimmingCharacters(in: .whitespaces), !configured.isEmpty {
            return configured
        }
        if let env = environment["ANTHROPIC_MODEL"]?.trimmingCharacters(in: .whitespaces), !env.isEmpty {
            return env
        }
        return Self.defaultModel
    }

    func read(
        textBlock: String, learnedRules: String?, calibration: [String: TagCalibration],
        apiKey: String, context: CallContext = .none
    ) async throws -> ReaderResult {
        let model = try await model()
        let userTurn = ReaderPrompt.userTurn(
            learnedRules: learnedRules, calibration: calibration, textBlock: textBlock, maxTags: maxTags)
        let rules = try await GuideStore.manual(settings: settings, fallback: fallbackRules)
        let block = rules == fallbackRules ? systemBlock : ReaderPrompt.systemBlock(rules: rules, buckets: buckets)
        let body = try Self.requestBody(model: model, systemBlock: block, userTurn: userTurn)
        let response = try await anthropic.messages(apiKey: apiKey, model: model, body: body, context: context)

        if let stop = response.stopReason, stop != "end_turn" {
            throw ReaderError.incomplete(stopReason: stop)
        }
        let text = response.text
        let answer = try Self.parse(text, knownSlugs: knownSlugs, maxTags: maxTags, logger: logger)
        let usage = response.usage
        let result = ReaderResult(
            answer: answer, model: response.model ?? model,
            inputTokens: usage?.inputTokens ?? 0, outputTokens: usage?.outputTokens ?? 0,
            cacheReadTokens: usage?.cacheReadInputTokens ?? 0, cacheWriteTokens: usage?.cacheCreationInputTokens ?? 0,
            rawJson: text)
        logger.info("reader \(result.model): \(answer.candidates.count) candidates, cache read \(result.cacheReadTokens), write \(result.cacheWriteTokens), in \(result.inputTokens), out \(result.outputTokens)")
        return result
    }

    // MARK: Request

    static func requestBody(model: String, systemBlock: String, userTurn: String) throws -> Data {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": [
                ["type": "text", "text": systemBlock, "cache_control": ["type": "ephemeral"]]
            ],
            "messages": [
                ["role": "user", "content": [["type": "text", "text": userTurn]]]
            ],
            "output_config": [
                "effort": "low",
                "format": ["type": "json_schema", "schema": ReaderPrompt.outputSchema],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    // MARK: Parsing

    /// Decodes the structured answer. Unknown slugs are dropped with a log line, duplicates
    /// collapse to their first occurrence, confidence is clamped to [0, 1], and the candidate
    /// list is capped at `maxTags`.
    static func parse(_ text: String, knownSlugs: Set<String>, maxTags: Int, logger: Logger) throws -> ReaderAnswer {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8), !cleaned.isEmpty else {
            throw ReaderError.malformed("empty response")
        }
        let raw: ReaderAnswer
        do {
            raw = try JSONDecoder().decode(ReaderAnswer.self, from: data)
        } catch {
            throw ReaderError.malformed(String(describing: error))
        }
        var seen = Set<String>()
        var candidates: [ReaderCandidate] = []
        for c in raw.candidates {
            let slug = c.slug.trimmingCharacters(in: .whitespaces).lowercased()
            guard knownSlugs.contains(slug) else {
                logger.warning("reader proposed unknown slug \(c.slug); dropped")
                continue
            }
            guard seen.insert(slug).inserted else { continue }
            candidates.append(ReaderCandidate(slug: slug, evidence: c.evidence, confidence: min(1, max(0, c.confidence))))
            if candidates.count == maxTags { break }
        }
        let alternates = raw.alternates
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { knownSlugs.contains($0) && !seen.contains($0) }
        return ReaderAnswer(residue: raw.residue.trimmingCharacters(in: .whitespacesAndNewlines), candidates: candidates, alternates: Array(NSOrderedSet(array: alternates)) as? [String] ?? alternates)
    }
}
