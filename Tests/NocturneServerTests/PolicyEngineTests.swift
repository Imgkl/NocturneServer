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

    // MARK: p1 (reader plus classifier)

    private let p1Floors: [String: Double] = ["ha-ha-ha": 0.80, "cat-and-mouse": 0.70]

    @Test func p1AppliesWhenReaderAndClassifierAgreeAboveTheFloor() {
        let classifier = classifierAnswer(["cat-and-mouse": 0.91, "ha-ha-ha": 0.62, "heist-energy": 0.9, "quiet-epics": 0.5], primary: "cat-and-mouse")
        let input = PolicyInput(
            candidates: [candidate("cat-and-mouse", 0.9, evidence: "duel"), candidate("ha-ha-ha", 0.85, evidence: "gags")],
            classifier: classifier, floors: p1Floors, defaultFloor: 0.70, high: [:], defaultHigh: 0.85)
        let d = PolicyEngine.decide(version: "p1", input: input)
        #expect(d.applied.map(\.slug) == ["cat-and-mouse"])
        #expect(d.applied.first?.evidence == "duel")
        #expect(d.applied.first?.probability == 0.91)
        #expect(d.suggested.map(\.slug) == ["heist-energy", "ha-ha-ha"])
        #expect(d.suggested.first { $0.slug == "ha-ha-ha" }?.reason == "reader yes, classifier 0.62 < 0.8")
        #expect(d.suggested.first { $0.slug == "heist-energy" }?.reason == "classifier 0.9, reader silent")
        #expect(d.suggested.first { $0.slug == "heist-energy" }?.evidence == "")
        #expect(!d.unsure)
        #expect(d.outcome == .review)
        #expect(d.reasons.contains("cat-and-mouse: applied, reader yes, classifier 0.91 ≥ 0.7"))
    }

    @Test func p1IsCleanWhenEverythingClearsItsFloor() {
        let classifier = classifierAnswer(["cat-and-mouse": 0.95, "ha-ha-ha": 0.9, "quiet-epics": 0.4], primary: "cat-and-mouse")
        let input = PolicyInput(candidates: [candidate("cat-and-mouse", 0.9), candidate("ha-ha-ha", 0.9)], classifier: classifier, floors: p1Floors)
        let d = PolicyEngine.decide(version: "p1", input: input)
        #expect(d.applied.map(\.slug) == ["cat-and-mouse", "ha-ha-ha"])
        #expect(d.suggested.isEmpty)
        #expect(d.outcome == .applied)
    }

    @Test func p1IsUnsureWhenThePassesDisagree() {
        let classifier = classifierAnswer(["cat-and-mouse": 0.95], primary: "cat-and-mouse", secondPick: "ha-ha-ha")
        let d = PolicyEngine.decide(version: "p1", input: PolicyInput(candidates: [candidate("cat-and-mouse", 0.9)], classifier: classifier, floors: [:], defaultFloor: 0.7))
        #expect(d.applied.map(\.slug) == ["cat-and-mouse"])
        #expect(d.unsure)
        #expect(d.outcome == .review)
        #expect(d.reasons.contains { $0.hasPrefix("unsure: the primary mood changed") })
    }

    @Test func p1WithoutAClassifierIsReaderOnly() {
        let d = PolicyEngine.decide(version: "p1", input: PolicyInput(candidates: [candidate("cat-and-mouse", 0.9)], floors: [:]))
        #expect(d.applied.isEmpty)
        #expect(d.suggested.map(\.slug) == ["cat-and-mouse"])
        #expect(d.unsure)
        #expect(d.outcome == .review)
        #expect(d.reasons.first == "no classifier answer; reader-only")
    }

    @Test func p1CapsAppliedByClassifierProbability() {
        var probs: [String: Double] = [:]
        var candidates: [ReaderCandidate] = []
        for i in 1...7 {
            probs["m\(i)"] = 0.99 - Double(i) * 0.01
            candidates.append(candidate("m\(i)", 0.9))
        }
        let d = PolicyEngine.decide(version: "p1", input: PolicyInput(candidates: candidates, classifier: classifierAnswer(probs, primary: "m1"), floors: [:], defaultFloor: 0.7, maxTags: 5))
        #expect(d.applied.map(\.slug) == ["m1", "m2", "m3", "m4", "m5"])
        #expect(d.suggested.map(\.slug) == ["m6", "m7"])
        #expect(d.suggested.first?.reason == "cap of 5 reached")
    }

    @Test func p1UnverifiedSourceStillAppliesNothing() {
        let classifier = classifierAnswer(["cat-and-mouse": 0.95], primary: "cat-and-mouse")
        let d = PolicyEngine.decide(version: "p1", input: PolicyInput(candidates: [candidate("cat-and-mouse", 0.9)], classifier: classifier, floors: [:], unverified: true))
        #expect(d.applied.isEmpty)
        #expect(d.suggested.first?.reason.contains("unverified") == true)
        #expect(d.outcome == .review)
    }

    @Test func p0UsesTheClassifierAlone() {
        let classifier = classifierAnswer(["cat-and-mouse": 0.9, "ha-ha-ha": 0.74, "quiet-epics": 0.3], primary: "cat-and-mouse")
        let d = PolicyEngine.decide(version: "p0", input: PolicyInput(candidates: [], classifier: classifier, floors: p1Floors, defaultFloor: 0.7))
        #expect(d.applied.map(\.slug) == ["cat-and-mouse"])
        #expect(d.suggested.map(\.slug) == ["ha-ha-ha"])
        #expect(d.suggested.first?.reason == "classifier 0.74 within 0.10 of 0.8")
        #expect(d.outcome == .review)
        #expect(PolicyEngine.decide(version: "p0", input: PolicyInput(candidates: [candidate("x", 0.9)], floors: [:])).outcome == .none)
    }

    @Test func prNeverApplies() {
        let d = PolicyEngine.decide(version: "pr", input: PolicyInput(candidates: [candidate("cat-and-mouse", 0.99)], classifier: classifierAnswer(["cat-and-mouse": 0.99]), floors: [:]))
        #expect(d.applied.isEmpty)
        #expect(d.suggested.map(\.slug) == ["cat-and-mouse"])
        #expect(d.suggested.first?.reason == "reader-only policy")
        #expect(d.unsure && d.outcome == .review)
    }
}
