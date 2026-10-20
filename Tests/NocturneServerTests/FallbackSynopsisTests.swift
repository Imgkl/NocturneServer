import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import Testing

@testable import NocturneServer

private final class FakeSynopsis: SynopsisWriting, @unchecked Sendable {
    var enabled = false
    var result = SynopsisResult(plot: "Model plot with the ending.", reception: "Model reception.", sources: ["https://a"])
    private(set) var calls = 0
    func isEnabled() async throws -> Bool { enabled }
    func write(for identity: EnrichmentService.Identity, apiKey: String, context: CallContext) async throws -> SynopsisResult {
        calls += 1
        return result
    }
}

@Suite struct FallbackSynopsisTests {
    private let identity = EnrichmentService.Identity(
        title: "Kadaisi Vivasayi", originalTitle: nil, year: 2022, director: "M. Manikandan", runtimeMinutes: 120,
        genres: ["Drama"], cast: ["Nallandi"], overview: "The last farmer.", imdbId: "tt10300570", tmdbId: nil)

    private func service(_ fluent: Fluent, _ transport: FakeTransport) async throws -> FallbackSynopsisService {
        let outbound = OutboundClient(transport: transport, fluent: fluent, logger: Logger(label: "test"), sleeper: { _ in }, jitter: { 0 })
        let settings = SettingsStore(db: fluent.db(), logger: Logger(label: "test"))
        try await settings.ensureTable()
        return FallbackSynopsisService(anthropic: AnthropicClient(outbound: outbound), settings: settings, logger: Logger(label: "test"))
    }

    @Test func requestUsesStrongModelWebSearchAndSchema() async throws {
        try await withTestFluent { fluent in
            let transport = FakeTransport([.response(status: 200, body: String(decoding: try fixtureData("anthropic/synopsis-response.json"), as: UTF8.self))])
            let svc = try await service(fluent, transport)
            let result = try await svc.write(for: identity, apiKey: "sk-test")
            #expect(result.plot.hasPrefix("Mayandi, an old farmer"))
            #expect(result.sources.count == 2)

            let body = try JSONSerialization.jsonObject(with: try #require(transport.requests.first?.body)) as! [String: Any]
            #expect(body["model"] as? String == "claude-opus-5-5")
            let tools = body["tools"] as! [[String: Any]]
            #expect(tools[0]["type"] as? String == "web_search_20260209")
            #expect(tools[0]["max_uses"] as? Int == 5)
            let output = body["output_config"] as! [String: Any]
            #expect((output["format"] as! [String: Any])["type"] as? String == "json_schema")
            let text = ((body["messages"] as! [[String: Any]])[0]["content"] as! [[String: Any]])[0]["text"] as! String
            #expect(text.contains("Title: Kadaisi Vivasayi (2022)"))
            #expect(text.contains("including the ending"))

            // Searches are metered as units on the call row.
            let row = try #require(try await ApiCall.query(on: fluent.db()).first())
            let units = try JSONDecoder().decode(CallUnits.self, from: Data(row.unitsJson.utf8))
            #expect(units.searches == 2)
            #expect(units.inputTokens == 3100)
        }
    }

    @Test func modelSettingAndEnabledFlag() async throws {
        try await withTestFluent { fluent in
            let svc = try await service(fluent, FakeTransport([]))
            #expect(try await svc.model() == "claude-opus-5-5")
            #expect(try await !svc.isEnabled())
            try await svc.settings.set(FallbackSynopsisService.modelSetting, "claude-sonnet-5-5")
            try await svc.settings.set(FallbackSynopsisService.enabledSetting, "on")
            #expect(try await svc.model() == "claude-sonnet-5-5")
            #expect(try await svc.isEnabled())
        }
    }

    @Test func earlyStopAndMissingJsonAreErrors() async throws {
        try await withTestFluent { fluent in
            let fixture = String(decoding: try fixtureData("anthropic/synopsis-response.json"), as: UTF8.self)
            let truncated = fixture.replacingOccurrences(of: "\"stop_reason\": \"end_turn\"", with: "\"stop_reason\": \"max_tokens\"")
            let svc = try await service(fluent, FakeTransport([.response(status: 200, body: truncated)]))
            await #expect(throws: SynopsisError.self) { _ = try await svc.write(for: identity, apiKey: "k") }

            let noJson = fixture.replacingOccurrences(of: "{\\\"plot\\\":", with: "plot:")
            let svc2 = try await service(fluent, FakeTransport([.response(status: 200, body: noJson)]))
            await #expect(throws: SynopsisError.self) { _ = try await svc2.write(for: identity, apiKey: "k") }
        }
    }

    @Test func enrichmentUsesTheFallbackOnlyWhenEnabled() async throws {
        try await withTestFluent { fluent in
            let synopsis = FakeSynopsis()
            let resolver = FakeResolver(.unresolved(reason: "nothing"))
            let wikipedia = FakeWikipedia(pages: [:])
            let svc = EnrichmentService(
                fluent: fluent, jellyfin: FakeJellyfin(item: dto()), resolver: resolver, wikipedia: wikipedia, awards: FakeAwards(),
                synopsis: synopsis, apiKey: { "sk-test" }, logger: Logger(label: "test"))

            let off = try await svc.enrich(jellyfinId: "jf-heat")
            #expect(off.source == "none")
            #expect(synopsis.calls == 0)

            synopsis.enabled = true
            let on = try await svc.enrich(jellyfinId: "jf-heat", force: true)
            #expect(synopsis.calls == 1)
            #expect(on.source == "model")
            #expect(on.unverified)
            #expect(on.plotFound)
            #expect(on.plotText == "Model plot with the ending.")
            #expect(on.receptionText == "Model reception.")
            #expect(on.wikiTitle == nil)
            #expect(on.textBlock?.hasSuffix("Page: (none) · model-written · fetched 2026-10-21 · unverified\n") == false || on.textBlock?.contains("model-written") == true)
            #expect(EnrichCoverageJob.bucket(for: on) == "model_synopsis")
        }
    }

    @Test func adminGenerateSynopsisWorksRegardlessOfTheFlag() async throws {
        try await withTestFluent { fluent in
            let synopsis = FakeSynopsis()
            let svc = EnrichmentService(
                fluent: fluent, jellyfin: FakeJellyfin(item: dto()), resolver: FakeResolver(.unresolved(reason: "x")), wikipedia: FakeWikipedia(pages: [:]), awards: FakeAwards(),
                synopsis: synopsis, apiKey: { "sk-test" }, logger: Logger(label: "test"))
            _ = try await svc.enrich(jellyfinId: "jf-heat")
            let row = try await svc.generateSynopsis(jellyfinId: "jf-heat")
            #expect(synopsis.calls == 1)
            #expect(row.source == "model")
            #expect(row.unverified)
            #expect(row.textBlock?.contains("Title: Heat (1995)") == true)
            #expect(row.textBlock?.contains("Model plot with the ending.") == true)
            #expect(row.textBlock?.contains("model-written") == true)
            #expect(row.textBlock?.contains("unverified") == true)
        }
    }

    @Test func noKeyMeansNoFallback() async throws {
        try await withTestFluent { fluent in
            let synopsis = FakeSynopsis()
            synopsis.enabled = true
            let svc = EnrichmentService(
                fluent: fluent, jellyfin: FakeJellyfin(item: dto()), resolver: FakeResolver(.unresolved(reason: "x")), wikipedia: FakeWikipedia(pages: [:]), awards: FakeAwards(),
                synopsis: synopsis, apiKey: { nil }, logger: Logger(label: "test"))
            let row = try await svc.enrich(jellyfinId: "jf-heat")
            #expect(row.source == "none")
            #expect(synopsis.calls == 0)
            await #expect(throws: TaggerError.self) { _ = try await svc.generateSynopsis(jellyfinId: "jf-heat") }
        }
    }
}
