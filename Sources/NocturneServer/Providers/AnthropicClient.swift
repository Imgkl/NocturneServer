import AsyncHTTPClient
import Foundation
import NIOCore

// MARK: - Response types (the subset the server reads)

struct AnthropicUsage: Decodable, Sendable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
    }

    var units: CallUnits {
        CallUnits(
            inputTokens: inputTokens, outputTokens: outputTokens,
            cacheReadTokens: cacheReadInputTokens, cacheWriteTokens: cacheCreationInputTokens)
    }
}

struct AnthropicContentBlock: Decodable, Sendable {
    let type: String
    let text: String?
}

struct AnthropicMessageResponse: Decodable, Sendable {
    let content: [AnthropicContentBlock]
    let model: String?
    let stopReason: String?
    let usage: AnthropicUsage?

    enum CodingKeys: String, CodingKey {
        case content, model, usage
        case stopReason = "stop_reason"
    }

    /// All text blocks joined; empty when the response carried none.
    var text: String {
        content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
    }
}

// MARK: - Client

/// Messages API over raw HTTP (Swift has no official SDK). Metering, retries and auth-failure
/// handling come from `OutboundClient`.
struct AnthropicClient: Sendable {
    static let messagesURL = "https://api.anthropic.com/v1/messages"
    static let apiVersion = "2023-06-01"

    let outbound: OutboundClient
    var url: String = Self.messagesURL

    /// Sends a pre-encoded Messages API body. `model` is passed separately for metering only;
    /// the body must carry the same `model` field.
    func messages(
        apiKey: String,
        model: String,
        body: Data,
        timeout: TimeAmount = .seconds(60),
        context: CallContext = .none
    ) async throws -> AnthropicMessageResponse {
        var request = HTTPClientRequest(url: url)
        request.method = .POST
        request.headers.add(name: "x-api-key", value: apiKey)
        request.headers.add(name: "anthropic-version", value: Self.apiVersion)
        request.headers.add(name: "content-type", value: "application/json")
        request.body = .bytes(body)

        let response = try await outbound.send(
            provider: "anthropic", endpoint: "/v1/messages", model: model, request: request,
            timeout: timeout, context: context
        ) { response in
            guard (200..<300).contains(response.status),
                  let decoded = try? response.decode(AnthropicMessageResponse.self),
                  let usage = decoded.usage
            else { return .none }
            return usage.units
        }
        return try response.decode(AnthropicMessageResponse.self)
    }
}
