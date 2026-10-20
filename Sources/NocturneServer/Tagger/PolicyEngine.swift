import Foundation

/// What the policy decided for one film. Pure data, stored on the decision row.
struct PolicyDecision: Sendable, Equatable {
    struct Applied: Codable, Sendable, Equatable {
        let slug: String
        let probability: Double
        let evidence: String
    }

    struct Suggested: Codable, Sendable, Equatable {
        let slug: String
        let probability: Double
        let evidence: String
        let reason: String
    }

    enum Outcome: String, Codable, Sendable {
        case applied
        case review
        case none
        case error
        case skipped
    }

    let applied: [Applied]
    let suggested: [Suggested]
    let unsure: Bool
    let outcome: Outcome
    let reasons: [String]

    static let empty = PolicyDecision(applied: [], suggested: [], unsure: true, outcome: .none, reasons: [])
}

struct PolicyInput: Sendable {
    let candidates: [ReaderCandidate]
    /// Per-slug floors; slugs missing here use `defaultFloor`.
    let floors: [String: Double]
    let defaultFloor: Double
    let maxTags: Int
    /// True when the story text was model-written; nothing auto-applies then.
    let unverified: Bool

    init(candidates: [ReaderCandidate], floors: [String: Double], defaultFloor: Double = 0.72, maxTags: Int = 5, unverified: Bool = false) {
        self.candidates = candidates
        self.floors = floors
        self.defaultFloor = defaultFloor
        self.maxTags = maxTags
        self.unverified = unverified
    }

    func floor(for slug: String) -> Double { floors[slug] ?? defaultFloor }
}

/// The only place a tag is decided. A pure function of stored answers, versioned, so the eval
/// can replay it. Phase 1 ships `p-legacy`: today's semantics (the reader's own confidence
/// against the per-bucket floors) with the decision recorded. Phase 2 adds the classifier
/// versions `p0`, `p1` and `pr`.
enum PolicyEngine {
    static let legacyVersion = "p-legacy"

    static func decide(version: String, input: PolicyInput) -> PolicyDecision {
        switch version {
        case legacyVersion:
            return legacy(input)
        default:
            preconditionFailure("unknown policy version \(version)")
        }
    }

    private static func legacy(_ input: PolicyInput) -> PolicyDecision {
        var applied: [PolicyDecision.Applied] = []
        var suggested: [PolicyDecision.Suggested] = []
        var reasons: [String] = []

        let ranked = input.candidates.sorted { $0.confidence > $1.confidence }
        for candidate in ranked {
            let floor = input.floor(for: candidate.slug)
            let p = Self.round(candidate.confidence)
            if candidate.confidence >= floor, applied.count < input.maxTags {
                applied.append(.init(slug: candidate.slug, probability: p, evidence: candidate.evidence))
                reasons.append("\(candidate.slug): applied, reader \(p) ≥ \(floor)")
            } else if candidate.confidence >= floor {
                let reason = "cap of \(input.maxTags) reached"
                suggested.append(.init(slug: candidate.slug, probability: p, evidence: candidate.evidence, reason: reason))
                reasons.append("\(candidate.slug): suggested, \(reason)")
            } else {
                let reason = "reader \(p) < \(floor)"
                suggested.append(.init(slug: candidate.slug, probability: p, evidence: candidate.evidence, reason: reason))
                reasons.append("\(candidate.slug): suggested, \(reason)")
            }
        }

        if input.unverified, !applied.isEmpty {
            for a in applied {
                suggested.insert(.init(slug: a.slug, probability: a.probability, evidence: a.evidence, reason: "story source is model-written (unverified)"), at: 0)
            }
            applied = []
            reasons.append("unverified story source: nothing auto-applies")
        }

        let unsure = applied.isEmpty
        let outcome: PolicyDecision.Outcome
        if applied.isEmpty {
            outcome = suggested.isEmpty ? .none : .review
        } else {
            outcome = (suggested.isEmpty && !unsure) ? .applied : .review
        }
        return PolicyDecision(applied: applied, suggested: suggested, unsure: unsure, outcome: outcome, reasons: reasons)
    }

    private static func round(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
