import Testing

@testable import NocturneServer

@Suite struct PolicyEngineTests {
    private let floors: [String: Double] = ["crime-grit-style": 0.82, "bittersweet-aftermath": 0.82, "time-twists": 0.65]

    @Test func appliesAtOrAboveFloorSuggestsBelow() {
        let input = PolicyInput(
            candidates: [candidate("cat-and-mouse", 0.72), candidate("bittersweet-aftermath", 0.61), candidate("time-twists", 0.65)],
            floors: floors)
        let d = PolicyEngine.decide(version: "p-legacy", input: input)
        #expect(d.applied.map(\.slug) == ["cat-and-mouse", "time-twists"])
        #expect(d.suggested.map(\.slug) == ["bittersweet-aftermath"])
        #expect(d.suggested.first?.reason == "reader 0.61 < 0.82")
        #expect(d.outcome == .review)
        #expect(!d.unsure)
        #expect(d.reasons.contains("bittersweet-aftermath: suggested, reader 0.61 < 0.82"))
    }

    @Test func appliedIsCappedByConfidence() {
        let candidates = (1...7).map { candidate("m\($0)", 0.99 - Double($0) * 0.01) }
        let d = PolicyEngine.decide(version: "p-legacy", input: PolicyInput(candidates: candidates, floors: [:], maxTags: 5))
        #expect(d.applied.count == 5)
        #expect(d.applied.first?.slug == "m1")
        #expect(d.suggested.map(\.slug) == ["m6", "m7"])
        #expect(d.suggested.first?.reason == "cap of 5 reached")
        #expect(d.outcome == .review)
    }

    @Test func unverifiedSourceMovesEverythingToReview() {
        let d = PolicyEngine.decide(
            version: "p-legacy",
            input: PolicyInput(candidates: [candidate("cat-and-mouse", 0.95)], floors: [:], unverified: true))
        #expect(d.applied.isEmpty)
        #expect(d.suggested.map(\.slug) == ["cat-and-mouse"])
        #expect(d.suggested.first?.reason.contains("unverified") == true)
        #expect(d.unsure)
        #expect(d.outcome == .review)
    }

    @Test func emptyCandidatesIsNoneAndUnsure() {
        let d = PolicyEngine.decide(version: "p-legacy", input: PolicyInput(candidates: [], floors: [:]))
        #expect(d.outcome == .none)
        #expect(d.unsure)
        #expect(d == .empty)
    }

    @Test func appliedOutcomeOnlyWhenNothingIsSuggested() {
        let strong = PolicyEngine.decide(version: "p-legacy", input: PolicyInput(candidates: [candidate("cat-and-mouse", 0.9)], floors: floors))
        #expect(strong.outcome == .applied)
        #expect(strong.applied.first?.probability == 0.9)
        let mixed = PolicyEngine.decide(version: "p-legacy", input: PolicyInput(candidates: [candidate("cat-and-mouse", 0.9), candidate("time-twists", 0.1)], floors: floors))
        #expect(mixed.outcome == .review)
    }
}
