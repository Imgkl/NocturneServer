import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import Testing

@testable import NocturneServer

@Suite struct ReaderServiceTests {
    private let config = NocturneConfiguration()

    private func reader(_ fluent: Fluent, _ transport: FakeTransport, env: [String: String] = [:]) async throws -> ReaderService {
        let outbound = OutboundClient(transport: transport, fluent: fluent, logger: Logger(label: "test"), sleeper: { _ in }, jitter: { 0 })
        let settings = SettingsStore(db: fluent.db(), logger: Logger(label: "test"))
        try await settings.ensureTable()
        return ReaderService(
            anthropic: AnthropicClient(outbound: outbound), settings: settings, buckets: config.moodBuckets,
            rules: config.autoTaggingPrompt, maxTags: 5, logger: Logger(label: "test"), environment: env)
    }

    private func fixtureBody() throws -> String {
        String(decoding: try fixtureData("anthropic/reader-response.json"), as: UTF8.self)
    }

    @Test func requestShapeCachesSystemBlockAndAsksForJsonSchema() async throws {
        try await withTestFluent { fluent in
            let transport = FakeTransport([.response(status: 200, body: try fixtureBody())])
            let svc = try await reader(fluent, transport)
            _ = try await svc.read(textBlock: "# Identity\nTitle: Heat (1995)", learnedRules: nil, calibration: [:], apiKey: "sk-test")

            let request = try #require(transport.requests.first)
            #expect(request.url == AnthropicClient.messagesURL)
            #expect(request.headers["anthropic-version"] == AnthropicClient.apiVersion)
            let body = try JSONSerialization.jsonObject(with: try #require(request.body)) as! [String: Any]
            #expect(body["model"] as? String == "claude-haiku-5-5")
            #expect(body["max_tokens"] as? Int == 4096)
            let system = body["system"] as! [[String: Any]]
            #expect((system[0]["cache_control"] as? [String: String])?["type"] == "ephemeral")
            #expect((system[0]["text"] as? String)?.contains("Available mood tags:") == true)
            let output = body["output_config"] as! [String: Any]
            #expect(output["effort"] as? String == "low")
            let format = output["format"] as! [String: Any]
            #expect(format["type"] as? String == "json_schema")
            #expect((format["schema"] as? [String: Any])?["additionalProperties"] as? Bool == false)
            let messages = body["messages"] as! [[String: Any]]
            let userText = ((messages[0]["content"] as! [[String: Any]])[0]["text"] as! String)
            #expect(userText.contains("## Film\n# Identity\nTitle: Heat (1995)"))
            #expect(!userText.contains("Available mood tags"))
        }
    }

    @Test func parsesDropsUnknownsCollapsesDuplicatesAndClamps() async throws {
        try await withTestFluent { fluent in
            let transport = FakeTransport([.response(status: 200, body: try fixtureBody())])
            let svc = try await reader(fluent, transport)
            let result = try await svc.read(textBlock: "x", learnedRules: nil, calibration: [:], apiKey: "sk-test")

            #expect(result.answer.residue.hasPrefix("A duel between two professionals"))
            #expect(result.answer.candidates.map(\.slug) == ["cat-and-mouse", "crime-grit-style", "bittersweet-aftermath"])
            #expect(result.answer.candidates.last?.confidence == 1.0)
            #expect(result.answer.alternates == ["slow-burn-sharp-blade"])
            #expect(result.cacheReadTokens == 9412)
            #expect(result.inputTokens == 1860)
            #expect(result.outputTokens == 214)
            #expect(result.model == "claude-haiku-5-5")
            #expect(result.rawJson.contains("\"residue\""))

            let rows = try await ApiCall.query(on: fluent.db()).all()
            #expect(rows.count == 1)
            #expect(rows.first?.model == "claude-haiku-5-5")
            let units = try JSONDecoder().decode(CallUnits.self, from: Data(rows.first!.unitsJson.utf8))
            #expect(units.cacheReadTokens == 9412)
            #expect(rows.first!.costUsd > 0)
        }
    }

    @Test func modelSettingWinsOverEnvAndDefault() async throws {
        try await withTestFluent { fluent in
            let transport = FakeTransport([.response(status: 200, body: try fixtureBody()), .response(status: 200, body: try fixtureBody())])
            let svc = try await reader(fluent, transport, env: ["ANTHROPIC_MODEL": "claude-opus-4-7"])
            #expect(try await svc.model() == "claude-opus-4-7")
            try await svc.settings.set(ReaderService.modelSetting, "claude-sonnet-5-5")
            #expect(try await svc.model() == "claude-sonnet-5-5")
            _ = try await svc.read(textBlock: "x", learnedRules: nil, calibration: [:], apiKey: "sk-test")
            let body = try JSONSerialization.jsonObject(with: try #require(transport.requests.first?.body)) as! [String: Any]
            #expect(body["model"] as? String == "claude-sonnet-5-5")

            let plain = try await reader(fluent, FakeTransport([]), env: [:])
            try await plain.settings.set(ReaderService.modelSetting, "")
            #expect(try await plain.model() == ReaderService.defaultModel)
        }
    }

    @Test func earlyStopIsAnError() async throws {
        try await withTestFluent { fluent in
            let truncated = try fixtureBody().replacingOccurrences(of: "\"stop_reason\": \"end_turn\"", with: "\"stop_reason\": \"max_tokens\"")
            let svc = try await reader(fluent, FakeTransport([.response(status: 200, body: truncated)]))
            await #expect(throws: ReaderError.self) {
                _ = try await svc.read(textBlock: "x", learnedRules: nil, calibration: [:], apiKey: "sk-test")
            }
        }
    }

    @Test func malformedJsonIsAnError() async throws {
        try await withTestFluent { fluent in
            let broken = try fixtureBody().replacingOccurrences(of: "{\\\"residue\\\"", with: "not json {\\\"residue\\\"")
            let svc = try await reader(fluent, FakeTransport([.response(status: 200, body: broken)]))
            await #expect(throws: ReaderError.self) {
                _ = try await svc.read(textBlock: "x", learnedRules: nil, calibration: [:], apiKey: "sk-test")
            }
        }
    }
}
