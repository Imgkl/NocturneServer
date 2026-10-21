import Foundation
import Testing

@testable import NocturneServer

@Suite struct MaybeItemsTests {

    @Test func alternatesAreKnownSlugsInOrderWithoutRepeats() {
        let known: Set<String> = ["ha-ha-ha", "cult-chaos", "film-school-shelf"]
        let json = #"{"residue":"x","candidates":[],"alternates":[" Cult-Chaos ","ha-ha-ha","made-up","ha-ha-ha","film-school-shelf"]}"#
        #expect(ReviewQueue.alternates(in: json, known: known) == ["cult-chaos", "ha-ha-ha", "film-school-shelf"])
        #expect(ReviewQueue.alternates(in: nil, known: known).isEmpty)
        #expect(ReviewQueue.alternates(in: "not json", known: known).isEmpty)
        #expect(ReviewQueue.alternates(in: #"{"residue":"x"}"#, known: known).isEmpty)
    }

    @Test func responseAppendsAlternatesAsMaybeItemsAfterTheDefendedMoods() throws {
        let stored = [SuggestionItem(slug: "ha-ha-ha", probability: 0.84, evidence: "\"hilarious\": comedy is the register", kind: .add, applied: true, reason: nil)]
        let sugg = TagSuggestion(jellyfinId: "jf-1", suggestedTags: ["ha-ha-ha"], confidence: 0.84, reasoning: "You leave laughing.", status: "pending")
        sugg.itemsJson = DecisionRecorder.json(stored)
        let response = TagSuggestionResponse(sugg, source: "wikipedia", alternates: ["cult-chaos", "ha-ha-ha", "rainy-day-rewinds"])
        let items = try #require(response.items)
        #expect(items.map(\.slug) == ["ha-ha-ha", "cult-chaos", "rainy-day-rewinds"])
        #expect(items[0].kind == .add)
        #expect(items[1].kind == .maybe && items[1].applied == false && items[1].probability == 0 && items[1].reason == "alternate")
        #expect(items[2].kind == .maybe)
        let encoded = try response.toJSONString()
        #expect(encoded.contains("\"kind\" : \"maybe\""))

        // A legacy row without items and without alternates keeps `items` absent.
        let legacy = TagSuggestion(jellyfinId: "jf-2", suggestedTags: ["cult-chaos"], confidence: 0.5, reasoning: nil, status: "pending")
        #expect(TagSuggestionResponse(legacy).items == nil)
        // Alternates alone still render, except the ones already on the suggested list.
        #expect(TagSuggestionResponse(legacy, alternates: ["cult-chaos", "ha-ha-ha"]).items?.map(\.slug) == ["ha-ha-ha"])
    }
}
