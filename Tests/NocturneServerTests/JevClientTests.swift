import Foundation
import Logging
import Testing

@testable import NocturneServer

@Suite struct JevClientTests {
    private let config = NocturneConfiguration()

    @Test func bodyCarriesOneQuestionPerMoodAndTwoPassesInDifferentOrders() throws {
        let built = JevClient.body(buckets: config.moodBuckets, model: "jev-1.13.0", textBlock: "# Identity\nTitle: Heat (1995)", guide: "Topic beats kind.", jellyfinId: "jf-heat")
        let data = Data(built.json.utf8)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["state"] as? [String: String])?["film"] == "# Identity\nTitle: Heat (1995)")
        #expect(object["model"] as? String == "jev-1.13.0")
        let questions = try #require(object["questions"] as? [String: Any])
        #expect(questions.count == 36 + 2)
        let haha = try #require(questions["mood_ha_ha_ha"] as? [String: Any])
        #expect(haha["type"] as? String == "noul")
        #expect((haha["instructions"] as? String)?.contains("Ha Ha Ha") == true)
        #expect((haha["instructions"] as? String)?.contains("Not for:") == true)
        let pass1 = try #require(questions["primary_pass1"] as? [String: Any])
        #expect(pass1["type"] as? String == "choice")
        #expect((pass1["instructions"] as? String)?.contains("Topic beats kind.") == true)
        let criteria = try #require(pass1["criteria"] as? [String: Any])
        #expect(criteria.count == 37)
        #expect(criteria["none"] as? String != nil)
        #expect(((criteria["cat-and-mouse"] as? [String: Any])?["covers"] as? String)?.contains("Qualifies when") == true)
        // The second pass lists the same options in another order, deterministic per film.
        #expect(built.order1 != built.order2)
        #expect(Set(built.order1) == Set(built.order2))
        #expect(built.order1.first == "antihero-study" && built.order1.last == "none")
        #expect(built.order2.first != built.order1.first)
        #expect(JevClient.shuffledOrder(built.order1, seed: "jf-heat") == built.order2)
        #expect(JevClient.shuffledOrder(built.order1, seed: "jf-other") != built.order2)
        // Written in order: pass 2's first option appears before its second in the text.
        let text = built.json
        let p2 = try #require(text.range(of: "\"primary_pass2\""))
        let tail = text[p2.upperBound...]
        let first = try #require(tail.range(of: "\"\(built.order2[0])\":"))
        let second = try #require(tail.range(of: "\"\(built.order2[1])\":"))
        #expect(first.lowerBound < second.lowerBound)
    }

    /// A learned rule lands inside the question of the mood it names, after that mood's own
    /// conditions and marked as overriding them; other moods do not carry it.
    @Test func learnedRulesLandInTheirOwnMoodQuestion() throws {
        let rules = [
            GuideStore.LearnedRule(boundary: "rainy-day-rewinds|regional-gems", text: "A loved mainstream Indian hit counts as regional-gems.", acceptedAt: Date()),
            GuideStore.LearnedRule(boundary: "ha-ha-ha|rainy-day-rewinds", text: "Comedy as a main draw is enough.", acceptedAt: Date()),
        ]
        let byMood = GuideStore.rulesByMood(rules)
        #expect(byMood["regional-gems"] == ["A loved mainstream Indian hit counts as regional-gems."])
        #expect(byMood["rainy-day-rewinds"] == ["Comedy as a main draw is enough."])  // names neither slug: filed under both
        #expect(byMood["ha-ha-ha"] == ["Comedy as a main draw is enough."])
        #expect(GuideStore.readerText(rules)?.contains("- regional-gems: A loved mainstream Indian hit") == true)

        let built = JevClient.body(buckets: config.moodBuckets, model: "jev-1.13.0", textBlock: "x", guide: nil, moodRules: byMood, jellyfinId: "jf")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(built.json.utf8)) as? [String: Any])
        let questions = try #require(object["questions"] as? [String: Any])
        let gems = try #require((questions[JevClient.questionKey(for: "regional-gems")] as? [String: Any])?["instructions"] as? String)
        let override = try #require(gems.range(of: "The owner's rules for this mood override any condition or exclusion above"))
        #expect(gems.range(of: "It fits only when every condition holds")!.lowerBound < override.lowerBound)
        #expect(gems.contains("A loved mainstream Indian hit counts as regional-gems."))
        let horror = try #require((questions[JevClient.questionKey(for: "horror-and-unease")] as? [String: Any])?["instructions"] as? String)
        #expect(!horror.contains("owner's rules"))
        let pass1 = try #require(questions["primary_pass1"] as? [String: Any])
        let gemsCriterion = try #require(((pass1["criteria"] as? [String: Any])?["regional-gems"] as? [String: Any])?["covers"] as? String)
        #expect(gemsCriterion.contains("A loved mainstream Indian hit"))
    }

    @Test func jsonStringEscapes() {
        #expect(JevClient.jsonString("a \"b\"\n\\c\ttab") == "\"a \\\"b\\\"\\n\\\\c\\ttab\"")
        #expect(JevClient.jsonString("\u{1}") == "\"\\u0001\"")
        #expect(JevClient.jsonString("héllo ☃") == "\"héllo ☃\"")
    }

    @Test func parseMapsMoodAnswersAndPasses() throws {
        let raw = """
        {"model":"jev-1.13.0","usage":{"input_tokens":12345},"answers":{
          "mood_ha_ha_ha":{"noul":0.91},
          "mood_cat_and_mouse":{"noul":0.12},
          "mood_made_up":{"noul":0.5},
          "primary_pass1":{"choice":"ha-ha-ha","probabilities":{"ha-ha-ha":0.8,"cult-chaos":0.1},"confidence":0.77},
          "primary_pass2":{"choice":"ha-ha-ha","probabilities":{"ha-ha-ha":0.75,"cult-chaos":0.15},"confidence":0.7}
        }}
        """
        let response = try JSONDecoder().decode(JevClient.Response.self, from: Data(raw.utf8))
        let order1 = config.moodBuckets.keys.sorted() + ["none"]
        let answer = JevClient.parse(response, buckets: config.moodBuckets, order1: order1, provider: "typesafe", fallbackModel: "x", rawJson: raw)
        #expect(answer.model == "jev-1.13.0")
        #expect(answer.inputTokens == 12345)
        #expect(answer.probabilities == ["ha-ha-ha": 0.91, "cat-and-mouse": 0.12])
        #expect(answer.pass1?.choice == "ha-ha-ha")
        #expect(answer.pass2?.confidence == 0.7)
        #expect(answer.agree)
        #expect(answer.primary == "ha-ha-ha")
        #expect(answer.rawJson == raw)
    }

    @Test func aPickOutsideTheOptionsIsDroppedAndCountsAsUnsure() throws {
        let raw = #"{"answers":{"primary_pass1":{"choice":"ha-ha-ha","probabilities":{"ha-ha-ha":0.8}},"primary_pass2":{"choice":"nope","probabilities":{"nope":0.9}}}}"#
        let response = try JSONDecoder().decode(JevClient.Response.self, from: Data(raw.utf8))
        let answer = JevClient.parse(response, buckets: config.moodBuckets, order1: ["ha-ha-ha", "none"], provider: "typesafe", fallbackModel: "jev-1.13.0", rawJson: raw)
        #expect(answer.model == "jev-1.13.0")
        #expect(answer.pass1 != nil && answer.pass2 == nil)
        #expect(!answer.agree)
        #expect(answer.primary == nil)
        #expect(answer.probabilities.isEmpty)
    }

    @Test func questionKeysRoundTrip() {
        for slug in config.moodBuckets.keys {
            #expect(JevClient.slug(forQuestionKey: JevClient.questionKey(for: slug), in: config.moodBuckets) == slug)
        }
        #expect(JevClient.slug(forQuestionKey: "primary_pass1", in: config.moodBuckets) == nil)
    }

    @Test func policyConfigDefaultsAndOverrides() async throws {
        let slugs = ["ha-ha-ha", "cat-and-mouse", "regional-gems"]
        let defaults = PolicyConfig.defaults(slugs: slugs)
        #expect(defaults.version == "p1")
        #expect(defaults.provider == .none)
        #expect(defaults.floors == ["ha-ha-ha": 0.80, "cat-and-mouse": 0.70, "regional-gems": 0.80])
        #expect(defaults.high.values.allSatisfy { $0 == 0.85 })
        try await withTestFluent { fluent in
            let settings = SettingsStore(db: fluent.db(), logger: Logger(label: "test"))
            try await settings.ensureTable()
            try await settings.set(PolicyConfig.floorsSetting, #"{"cat-and-mouse":0.75,"unknown":0.1,"ha-ha-ha":1.5}"#)
            try await settings.set(PolicyConfig.highSetting, "not json")
            try await settings.set(PolicyConfig.versionSetting, "p0")
            try await settings.set(PolicyConfig.providerSetting, "jev")
            let loaded = try await PolicyConfig.load(settings: settings, slugs: slugs)
            #expect(loaded.version == "p0")
            #expect(loaded.provider == .jev)
            #expect(loaded.floors == ["ha-ha-ha": 1.0, "cat-and-mouse": 0.75, "regional-gems": 0.80])
            #expect(loaded.high == defaults.high)
            try await settings.set(PolicyConfig.versionSetting, "p9")
            #expect(try await PolicyConfig.load(settings: settings, slugs: slugs).version == "p1")
        }
    }
}
