import FluentKit
import Foundation
import Logging
import Testing

@testable import NocturneServer

@Suite struct TeachServiceTests {
    private let config = NocturneConfiguration()

    @Test func boundaryKeysFollowTheKnownPairOrder() {
        #expect(TeachService.Boundary("emotional-gut-punch", "bittersweet-aftermath").key == "bittersweet-aftermath|emotional-gut-punch")
        #expect(TeachService.Boundary("cat-and-mouse", "antihero-study").left == "antihero-study")
        #expect(TeachService.Boundary("zzz", "aaa").key == "aaa|zzz")
        #expect(TeachService.Boundary(key: "ha-ha-ha|rainy-day-rewinds")?.right == "rainy-day-rewinds")
        #expect(TeachService.Boundary(key: "rainy-day-rewinds|ha-ha-ha")?.key == "ha-ha-ha|rainy-day-rewinds")
        #expect(TeachService.Boundary(key: "broken") == nil)
        #expect(TeachService.Boundary(key: "a|a") == nil)
        #expect(TeachService.Boundary.isKnown("film-school-shelf", "modern-masterpieces"))
        #expect(!TeachService.Boundary.isKnown("film-school-shelf", "ha-ha-ha"))
    }

    @Test func boundaryPicksTheKnownPairThenTheModelsTopTwo() {
        // The system applied one mood, the owner added a known neighbour.
        let a = TeachService.boundary(systemApplied: ["emotional-gut-punch"], adminMoods: ["emotional-gut-punch", "bittersweet-aftermath"], classifier: [:], reader: [:])
        #expect(a?.key == "bittersweet-aftermath|emotional-gut-punch")
        // An unknown pair still forms a boundary between the system's pick and the owner's extra mood.
        let b = TeachService.boundary(systemApplied: ["ha-ha-ha"], adminMoods: ["ha-ha-ha", "visual-worship"], classifier: [:], reader: [:])
        #expect(b?.key == "ha-ha-ha|visual-worship")
        // No disagreement: the classifier's top two.
        let c = TeachService.boundary(systemApplied: [], adminMoods: [], classifier: ["cat-and-mouse": 0.7, "crime-grit-style": 0.9, "quiet-epics": 0.1], reader: ["ha-ha-ha": 0.9])
        #expect(c?.key == "cat-and-mouse|crime-grit-style")
        // No classifier: the reader's top two.
        let d = TeachService.boundary(systemApplied: [], adminMoods: [], classifier: [:], reader: ["ha-ha-ha": 0.9, "rainy-day-rewinds": 0.8])
        #expect(d?.key == "ha-ha-ha|rainy-day-rewinds")
        #expect(TeachService.boundary(systemApplied: [], adminMoods: [], classifier: [:], reader: ["ha-ha-ha": 0.9]) == nil)
    }

    @Test func parseRulesAcceptsFencedJsonAndCaps() throws {
        let text = "```json\n{\"rules\": [\" A film whose ending is a reunion is rainy-day-rewinds. \", \"\", \"two\", \"three\", \"four\"]}\n```"
        #expect(try TeachService.parseRules(text) == ["A film whose ending is a reunion is rainy-day-rewinds.", "two", "three"])
        #expect(throws: TeachError.self) { _ = try TeachService.parseRules("not json") }
    }

    @Test func rulesRequestCarriesTheBoundaryTheGuideAndTheAnswers() throws {
        let boundary = TeachService.Boundary("ha-ha-ha", "rainy-day-rewinds")
        let films = [
            TeachService.Film(jellyfinId: "1", title: "Om Shanti Om", residue: "campy", leftProbability: 0.7, rightProbability: 0.86, systemPick: "ha-ha-ha", adminPick: "rainy-day-rewinds", answer: "rainy-day-rewinds"),
            TeachService.Film(jellyfinId: "2", title: "Airplane!", residue: "gags", leftProbability: 0.95, rightProbability: 0.5, systemPick: "ha-ha-ha", adminPick: nil, answer: "ha-ha-ha"),
            TeachService.Film(jellyfinId: "3", title: "Heat", residue: "duel", leftProbability: nil, rightProbability: 0.2, systemPick: nil, adminPick: nil, answer: "neither"),
        ]
        let body = try TeachService.rulesRequestBody(model: "claude-opus-5-5", boundary: boundary, buckets: config.moodBuckets, manual: "Rule 0: Residue first", films: films)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["model"] as? String == "claude-opus-5-5")
        let messages = try #require(object["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? String)
        #expect(content.contains("ha-ha-ha: Ha Ha Ha"))
        #expect(content.contains("Rule 0: Residue first"))
        #expect(content.contains("Om Shanti Om: owner says right (rainy-day-rewinds)"))
        #expect(content.contains("Airplane!: owner says left (ha-ha-ha)"))
        #expect(content.contains("Heat: owner says neither"))
        #expect(content.contains("left -, right 0.20"))
        let format = try #require((object["output_config"] as? [String: Any])?["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
    }

    @Test func answersUpsertAndRulesLandInTheGuide() async throws {
        try await withTestFluent { fluent in
            try await Movie(jellyfinId: "jf-1").save(on: fluent.db())
            let settings = SettingsStore(db: fluent.db(), logger: Logger(label: "test"))
            try await settings.ensureTable()
            let reader = ScriptedReader(answer: answer([candidate("ha-ha-ha", 0.9)]))
            let (pipeline, movies, _) = try await makePipeline(fluent, config: config, enricher: ScriptedEnricher(), reader: reader)
            let queue = ReviewQueue(fluent: fluent, config: config, movies: movies, pipeline: pipeline)
            let runs = RunService(fluent: fluent)
            let backfill = BackfillJob(runService: runs, pipeline: pipeline, queue: queue, fluent: fluent, config: config)
            let anthropic = AnthropicClient(outbound: OutboundClient(transport: FakeTransport([]), fluent: fluent))
            let teach = TeachService(fluent: fluent, config: config, settings: settings, anthropic: anthropic, backfill: backfill, logger: Logger(label: "test"))

            await #expect(throws: TeachError.self) { try await teach.answer(jellyfinId: "jf-1", boundaryKey: "ha-ha-ha|rainy-day-rewinds", answer: "cult-chaos") }
            await #expect(throws: TeachError.self) { try await teach.answer(jellyfinId: "jf-1", boundaryKey: "nope", answer: "neither") }
            try await teach.answer(jellyfinId: "jf-1", boundaryKey: "rainy-day-rewinds|ha-ha-ha", answer: "ha-ha-ha")
            try await teach.answer(jellyfinId: "jf-1", boundaryKey: "ha-ha-ha|rainy-day-rewinds", answer: "neither")
            let rows = try await TeachAnswer.query(on: fluent.db()).all()
            #expect(rows.count == 1)
            #expect(rows.first?.boundary == "ha-ha-ha|rainy-day-rewinds" && rows.first?.answer == "neither")

            #expect(try await GuideStore.version(settings: settings) == 1)
            let accepted = try await teach.acceptRules(boundaryKey: "ha-ha-ha|rainy-day-rewinds", rules: [" A masala film with a comedy track is rainy-day-rewinds, not ha-ha-ha. ", ""])
            #expect(accepted.rules == 1)
            #expect(accepted.guideVersion == 2)
            #expect(accepted.regradeFilms == 0 && !accepted.regradeStarted)
            let learned = try await GuideStore.learned(settings: settings)
            #expect(learned.count == 1 && learned.first?.boundary == "ha-ha-ha|rainy-day-rewinds")
            #expect(try await GuideStore.learnedText(settings: settings) == "- A masala film with a comedy track is rainy-day-rewinds, not ha-ha-ha.")
            let full = try await GuideStore.full(settings: settings, fallback: "manual text")
            #expect(full.hasPrefix("manual text") && full.contains("Learned from the owner's own decisions"))
            // A duplicate rule is not added twice; removing it empties the list and bumps the version.
            _ = try await teach.acceptRules(boundaryKey: "ha-ha-ha|rainy-day-rewinds", rules: ["A masala film with a comedy track is rainy-day-rewinds, not ha-ha-ha."])
            #expect(try await GuideStore.learned(settings: settings).count == 1)
            #expect(try await teach.removeRule(at: 0) == 4)
            #expect(try await GuideStore.learned(settings: settings).isEmpty)
            await #expect(throws: TeachError.self) { try await teach.removeRule(at: 0) }
            // The manual guide: edited text wins, an empty edit falls back to the bundled one.
            _ = try await GuideStore.setManual("My rules.", settings: settings)
            #expect(try await GuideStore.manual(settings: settings, fallback: "bundled") == "My rules.")
            _ = try await GuideStore.setManual("", settings: settings)
            #expect(try await GuideStore.manual(settings: settings, fallback: "bundled") == "bundled")
        }
    }
}
