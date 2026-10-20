import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import Testing

@testable import NocturneServer

@Suite struct DecisionRecorderTests {

    @Test func beginThenCompleteWritesEverythingAndPointsTheMovieAtIt() async throws {
        try await withTestFluent { fluent in
            try await Movie(jellyfinId: "jf-1").save(on: fluent.db())
            let recorder = DecisionRecorder(fluent: fluent, logger: Logger(label: "test"))

            let opened = try await recorder.begin(jellyfinId: "jf-1", runId: nil, policyVersion: "p-legacy")
            #expect(opened.outcome == "error")
            let id = try opened.requireID()
            for cost in [0.001, 0.002] {
                try await ApiCall(runId: nil, decisionId: id, provider: "anthropic", endpoint: "/v1/messages", model: "m", attempt: 1, httpStatus: 200, durationMs: 1, unitsJson: "{}", costUsd: cost).save(on: fluent.db())
            }
            try await ApiCall(runId: nil, decisionId: UUID(), provider: "anthropic", endpoint: "/v1/messages", model: "m", attempt: 1, httpStatus: 200, durationMs: 1, unitsJson: "{}", costUsd: 5).save(on: fluent.db())

            let enrichment = MovieEnrichment(jellyfinId: "jf-1")
            enrichment.inputHash = "abc"
            enrichment.enrichVersion = 1
            enrichment.source = "wikipedia"
            let policy = PolicyEngine.decide(version: "p-legacy", input: PolicyInput(candidates: [candidate("cat-and-mouse", 0.9), candidate("heist-energy", 0.5)], floors: [:]))
            let reader = ReaderResult(answer: answer(policy.applied.map { candidate($0.slug, $0.probability) }), model: "claude-haiku-5-5", inputTokens: 1, outputTokens: 1, cacheReadTokens: 1, cacheWriteTokens: 0, rawJson: "{\"residue\":\"x\"}")

            try await recorder.complete(opened, with: .init(enrichment: enrichment, reader: reader, policy: policy, outcome: policy.outcome, reasons: policy.reasons, models: ["extra": "1"]))

            let row = try #require(try await Decision.find(id, on: fluent.db()))
            #expect(row.outcome == "review")
            #expect(row.inputHash == "abc")
            #expect(row.enrichVersion == 1)
            #expect(row.readerJson == "{\"residue\":\"x\"}")
            #expect(row.appliedJson.contains("cat-and-mouse"))
            #expect(row.suggestedJson.contains("heist-energy"))
            #expect(!row.unsure)
            #expect(abs(row.costUsd - 0.003) < 1e-9)
            let models = try JSONDecoder().decode([String: String].self, from: Data(row.modelsJson.utf8))
            #expect(models["reader"] == "claude-haiku-5-5")
            #expect(models["enrichment_source"] == "wikipedia")
            #expect(models["extra"] == "1")
            #expect(row.taxonomyVersion == DecisionRecorder.taxonomyVersion)
            let movie = try #require(try await Movie.query(on: fluent.db()).filter(\.$jellyfinId == "jf-1").first())
            #expect(movie.currentDecisionId == id)
        }
    }

    @Test func itemsListAppliedThenSuggested() {
        let policy = PolicyEngine.decide(version: "p-legacy", input: PolicyInput(candidates: [candidate("cat-and-mouse", 0.9, evidence: "chase"), candidate("heist-energy", 0.5, evidence: "plan")], floors: [:]))
        let items = DecisionRecorder.items(from: policy)
        #expect(items.count == 2)
        #expect(items[0] == SuggestionItem(slug: "cat-and-mouse", probability: 0.9, evidence: "chase", kind: .add, applied: true, reason: nil))
        #expect(items[1].applied == false)
        #expect(items[1].reason == "reader 0.5 < 0.72")
    }
}
