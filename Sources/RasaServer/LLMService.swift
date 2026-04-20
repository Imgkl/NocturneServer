import Foundation
import AsyncHTTPClient
import Logging

final class LLMService: Sendable {
    private let httpClient: HTTPClient
    private let logger = Logger(label: "LLMService")
    private let anthropicModel: String

    init(httpClient: HTTPClient) {
        self.httpClient = httpClient
        self.anthropicModel = ProcessInfo.processInfo.environment["ANTHROPIC_MODEL"] ?? "claude-opus-4-7"
    }

    func generateTags(
        for context: MovieContext,
        using provider: LLMProvider,
        availableTags: [String: MoodBucket],
        customPrompt: String?,
        maxTags: Int = 4,
        externalInfo: String? = nil
    ) async throws -> AutoTagResponse {

        let movieContext = buildMovieContext(from: context)
        let tagsContext = buildTagsContext(availableTags: availableTags)
        let prompt = buildPrompt(
            movieContext: movieContext,
            tagsContext: tagsContext,
            customPrompt: customPrompt,
            maxTags: maxTags,
            externalInfo: externalInfo
        )

        logger.info("Generating tags for movie: \(context.title) using \(provider.name)")

        switch provider {
        case .anthropic(let apiKey):
            return try await generateWithAnthropic(prompt: prompt, apiKey: apiKey, maxTags: maxTags)
        }
    }

    func refineTags(
        for context: MovieContext,
        using provider: LLMProvider,
        availableTags: [String: MoodBucket],
        initial: AutoTagResponse,
        externalInfo: String?,
        maxTags: Int
    ) async throws -> AutoTagResponse {
        let movieContext = buildMovieContext(from: context)
        let tagsContext = buildTagsContext(availableTags: availableTags)
        let prompt = buildRefinePrompt(
            movieContext: movieContext,
            tagsContext: tagsContext,
            initial: initial,
            externalInfo: externalInfo,
            maxTags: maxTags
        )
        switch provider {
        case .anthropic(let apiKey):
            return try await generateWithAnthropic(prompt: prompt, apiKey: apiKey, maxTags: maxTags)
        }
    }

    // MARK: - Anthropic Integration

    private func generateWithAnthropic(prompt: String, apiKey: String, maxTags: Int) async throws -> AutoTagResponse {
        let url = "https://api.anthropic.com/v1/messages"

        let requestBody = AnthropicRequest(
            model: anthropicModel,
            maxTokens: 500,
            messages: [
                AnthropicMessage(
                    role: "user",
                    content: [AnthropicContent(type: "text", text: prompt)]
                )
            ],
            system: "You are a film expert helping categorize movies by mood. Return only valid JSON."
        )

        var request = HTTPClientRequest(url: url)
        request.method = .POST
        request.headers.add(name: "x-api-key", value: apiKey)
        request.headers.add(name: "anthropic-version", value: "2023-06-01")
        request.headers.add(name: "content-type", value: "application/json")

        let jsonData = try JSONEncoder().encode(requestBody)
        request.body = .bytes(jsonData)

        let response: HTTPClientResponse
        do {
            response = try await httpClient.execute(request, timeout: .seconds(45))
        } catch {
            throw LLMError.httpError(502, "Network error contacting Anthropic: \(error.localizedDescription)")
        }

        guard response.status == .ok else {
            throw LLMError.httpError(response.status.code, "Anthropic API error")
        }

        let data = try await response.body.collect(upTo: 1024 * 1024)
        let anthropicResponse = try JSONDecoder().decode(AnthropicResponse.self, from: data)

        guard let content = anthropicResponse.content.first?.text else {
            throw LLMError.invalidResponse("No content in Anthropic response")
        }

        return try parseTagResponse(content)
    }

    // MARK: - Prompt Building

    private func buildMovieContext(from context: MovieContext) -> String {
        let lines = [
            "Title: \(context.title)",
            context.originalTitle.map { "Original Title: \($0)" },
            context.year.map { "Year: \($0)" },
            context.overview.map { "Plot: \($0)" },
            context.runtimeMinutes.map { "Runtime: \($0) minutes" },
            context.director.map { "Director: \($0)" },
            !context.genres.isEmpty ? "Genres: \(context.genres.joined(separator: ", "))" : nil,
            !context.cast.isEmpty ? "Cast: \(context.cast.prefix(5).joined(separator: ", "))" : nil
        ].compactMap { $0 }

        return lines.joined(separator: "\n")
    }

    private func buildTagsContext(availableTags: [String: MoodBucket]) -> String {
        let tags = availableTags.map { slug, bucket in
            let keywords = (bucket.tags ?? []).joined(separator: ", ")
            let extras = keywords.isEmpty ? "" : " [keywords: \(keywords)]"
            return "\(slug): \(bucket.title) - \(bucket.description)\(extras)"
        }.sorted().joined(separator: "\n")

        return "Available mood tags:\n\(tags)"
    }

    private func buildPrompt(
        movieContext: String,
        tagsContext: String,
        customPrompt: String?,
        maxTags: Int,
        externalInfo: String?
    ) -> String {
        let basePrompt = customPrompt ?? """
        You are a meticulous film taxonomy expert. Pick the 1–\(maxTags) mood tags that best describe
        the movie's DOMINANT EMOTIONAL REGISTER — the feeling a viewer leaves with after watching the
        whole film — not its individual scenes.

        Rule 1 — Dominant register, not flavor notes
        • A sad/tragic film with funny lines is NOT "ha-ha-ha".
        • A film with a romantic subplot but dark themes is NOT "feel-good-romance".
        • A heavy or intense film is NOT "rainy-day-rewinds".
        • A coming-of-age subplot in a broader drama is NOT "coming-of-age" unless identity-becoming is the central arc.

        Rule 2 — Evidence or drop the tag
        Cite concrete evidence from the overview/summary for every tag. No citation → no tag.

        Rule 3 — Specific guards
        • dialogue-driven: only when verbal exchanges are the PRIMARY engine of tension; most dramas are not.
        • time-twists: requires explicit temporal mechanics (loops, travel, branching timelines). Nonlinear editing ≠ time twists.
        • psychological-pressure-cooker: requires mind-unraveling; spatial-confinement tension → prefer one-room-pressure-cooker.
        • ha-ha-ha: primary register must be comedy; dark comedies with tragic endings do NOT qualify.
        • feel-good-romance: uplifting arc AND romance is the engine; tragic romances do NOT qualify.
        • rainy-day-rewinds: comfort-first, low-stakes, warm rhythm; heavy films do NOT qualify.
        • modern-masterpieces: only with explicit acclaim evidence (Oscar, Palme d'Or, critic consensus, landmark).

        Rule 4 — Prefer precision
        Fewer tags when unsure. One well-justified tag beats three loose ones. Cap at \(maxTags).
        Calibrate confidence 0.70–0.95 when strong; lower otherwise.

        Rule 5 — Valid slugs only; do not invent tags.

        In `reasoning`, first state the movie's dominant emotional register in one sentence, then cite
        the evidence for each chosen tag.
        """

        return """
        \(basePrompt)

        Movie information:
        \(movieContext)

        \(tagsContext)

        Additional external context (optional):
        \(externalInfo ?? "(none)")

        Please respond with a JSON object in exactly this format:
        {
            "suggestions": ["tag-slug-1", "tag-slug-2"],
            "confidence": 0.85,
            "reasoning": "Brief explanation of why these tags fit"
        }

        Return only valid JSON, nothing else.
        """
    }

    private func buildRefinePrompt(
        movieContext: String,
        tagsContext: String,
        initial: AutoTagResponse,
        externalInfo: String?,
        maxTags: Int
    ) -> String {
        let critiqueGuardrails = """
        You are critiquing an earlier tag set. Be stricter than the first pass.
        Apply the DOMINANT-REGISTER test: a tag is only valid if it describes the WHOLE film, not a scene or subplot.

        Drop a tag if ANY of these are true:
        • ha-ha-ha, but the film is primarily sad, tragic, or melancholic (some humor ≠ comedy).
        • feel-good-romance, but the arc is ambivalent or tragic (romantic subplot ≠ feel-good).
        • rainy-day-rewinds, but the film is heavy, disturbing, or high-stakes.
        • coming-of-age, but the film is not centered on identity-becoming.
        • dialogue-driven, but the film has meaningful action/set pieces; verbal exchanges are not the PRIMARY engine.
        • time-twists, without explicit temporal mechanics (loop/travel/branching). Nonlinear editing alone ≠ qualifying.
        • psychological-pressure-cooker, when the tension is primarily spatial — prefer one-room-pressure-cooker.
        • modern-masterpieces, without explicit acclaim evidence (Oscar, Palme d'Or, critic consensus, landmark).
        • Any tag lacking a concrete phrase from the overview/external summary you can quote in `reasoning`.

        IMPORTANT: You MUST return at least 1 tag — the single strongest survivor. Never return an empty array.
        If every initial tag fails its guard, keep the ONE that best matches the film's dominant register,
        even if weakly supported — then lower confidence accordingly (0.50–0.65).

        Keep at most \(maxTags). Fewer is better. For each kept tag, quote the exact evidence in `reasoning`.

        Output format MUST match exactly:
        {"suggestions": ["tag-1"], "confidence": 0.6, "reasoning": "..."}
        """
        return """
        \(critiqueGuardrails)

        Movie information:
        \(movieContext)

        \(tagsContext)

        Additional external context (optional):
        \(externalInfo ?? "(none)")

        Initial tags to critique:
        {"suggestions": \(try! initial.toJSONString()), "note": "Only use the 'suggestions' from above; re-evaluate them."}
        """
    }

    // MARK: - Response Parsing

    private func parseTagResponse(_ content: String) throws -> AutoTagResponse {
        let cleanContent = content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleanContent.data(using: .utf8) else {
            throw LLMError.invalidResponse("Could not encode response as UTF-8")
        }

        do {
            return try JSONDecoder().decode(AutoTagResponse.self, from: data)
        } catch {
            logger.error("Failed to parse LLM response: \(cleanContent)")
            throw LLMError.invalidResponse("Failed to parse JSON response: \(error)")
        }
    }
}

// MARK: - LLM Provider

enum LLMProvider: Sendable {
    case anthropic(apiKey: String)

    var name: String {
        switch self {
        case .anthropic: return "Anthropic"
        }
    }
}

// MARK: - External Info

extension LLMService {
    struct WikiSummary: Decodable { let extract: String? }

    func fetchExternalSummary(title: String, year: Int?) async -> String? {
        let base = "https://en.wikipedia.org/api/rest_v1/page/summary/"
        var candidates: [String] = []
        if let year = year {
            candidates.append("\(title) (\(year))")
        }
        candidates.append(title)

        for candidate in candidates {
            let encoded = candidate.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? candidate
            let url = base + encoded
            var req = HTTPClientRequest(url: url)
            req.method = .GET
            do {
                let resp = try await httpClient.execute(req, timeout: .seconds(8))
                guard resp.status == .ok else { continue }
                let data = try await resp.body.collect(upTo: 512 * 1024)
                let decoded = try? JSONDecoder().decode(WikiSummary.self, from: data)
                if let extract = decoded?.extract, !extract.isEmpty {
                    return extract
                }
            } catch {
                continue
            }
        }
        return nil
    }
}

// MARK: - API Models

struct AnthropicRequest: Codable {
    let model: String
    let maxTokens: Int
    let messages: [AnthropicMessage]
    let system: String

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case messages
        case system
    }
}

struct AnthropicMessage: Codable {
    let role: String
    let content: [AnthropicContent]
}

struct AnthropicResponse: Codable {
    let content: [AnthropicContent]
    let model: String
    let role: String
    let stopReason: String?

    enum CodingKeys: String, CodingKey {
        case content
        case model
        case role
        case stopReason = "stop_reason"
    }
}

struct AnthropicContent: Codable {
    let type: String
    let text: String
}

// MARK: - Errors

enum LLMError: Error, CustomStringConvertible {
    case httpError(UInt, String)
    case invalidResponse(String)

    var description: String {
        switch self {
        case .httpError(let code, let message):
            return "LLM API Error (\(code)): \(message)"
        case .invalidResponse(let details):
            return "Invalid LLM response: \(details)"
        }
    }
}
