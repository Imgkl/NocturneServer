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
    /// The classifier of record's answer; nil when no classifier ran.
    let classifier: ClassifierAnswer?
    /// Per-slug floors; slugs missing here use `defaultFloor`.
    let floors: [String: Double]
    let defaultFloor: Double
    /// Per-slug "high" lines: a classifier probability at or above it makes a suggestion out of a
    /// mood the reader never named.
    let high: [String: Double]
    let defaultHigh: Double
    let maxTags: Int
    /// True when the story text was model-written; nothing auto-applies then.
    let unverified: Bool

    init(
        candidates: [ReaderCandidate], classifier: ClassifierAnswer? = nil, floors: [String: Double], defaultFloor: Double = 0.72,
        high: [String: Double] = [:], defaultHigh: Double = 0.85, maxTags: Int = 5, unverified: Bool = false
    ) {
        self.candidates = candidates
        self.classifier = classifier
        self.floors = floors
        self.defaultFloor = defaultFloor
        self.high = high
        self.defaultHigh = defaultHigh
        self.maxTags = maxTags
        self.unverified = unverified
    }

    func floor(for slug: String) -> Double { floors[slug] ?? defaultFloor }
    func high(for slug: String) -> Double { high[slug] ?? defaultHigh }
}

/// The only place a tag is decided. A pure function of stored answers, versioned, so the eval
/// can replay it. `p-legacy` is the reader's own confidence against the per-bucket floors;
/// `p1` is the reader plus the classifier of record; `p0` is the classifier alone; `pr` is the
/// reader alone with nothing auto-applied.
enum PolicyEngine {
    static let legacyVersion = "p-legacy"
    static let p1Version = "p1"
    static let p0Version = "p0"
    static let readerOnlyVersion = "pr"
    static let versions = [legacyVersion, p1Version, p0Version, readerOnlyVersion]

    static func decide(version: String, input: PolicyInput) -> PolicyDecision {
        switch version {
        case legacyVersion:
            return legacy(input)
        case p1Version:
            return p1(input)
        case p0Version:
            return p0(input)
        case readerOnlyVersion:
            return readerOnly(input)
        default:
            preconditionFailure("unknown policy version \(version)")
        }
    }

    // MARK: p-legacy

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
        return finish(input: input, applied: applied, suggested: suggested, reasons: reasons, unsure: applied.isEmpty)
    }

    // MARK: p1 (reader plus classifier)

    private static func p1(_ input: PolicyInput) -> PolicyDecision {
        guard let classifier = input.classifier else {
            // Without a classifier answer p1 cannot run; the reader's candidates all wait for a human.
            var d = readerOnly(input)
            d = PolicyDecision(applied: d.applied, suggested: d.suggested, unsure: true, outcome: d.outcome, reasons: ["no classifier answer; reader-only"] + d.reasons)
            return d
        }
        var applied: [PolicyDecision.Applied] = []
        var suggested: [PolicyDecision.Suggested] = []
        var reasons: [String] = []
        let byReader = Dictionary(uniqueKeysWithValues: input.candidates.map { ($0.slug, $0) })
        let slugs = Array(Set(byReader.keys).union(classifier.probabilities.keys)).sorted()

        for slug in slugs {
            let reader = byReader[slug]
            let evidence = reader?.evidence ?? ""
            let floor = input.floor(for: slug)
            let high = input.high(for: slug)
            if let raw = classifier.probabilities[slug] {
                let p = Self.round(raw)
                if reader != nil, raw >= floor {
                    applied.append(.init(slug: slug, probability: p, evidence: evidence))
                    reasons.append("\(slug): applied, reader yes, classifier \(p) ≥ \(floor)")
                } else if reader != nil {
                    let reason = "reader yes, classifier \(p) < \(floor)"
                    suggested.append(.init(slug: slug, probability: p, evidence: evidence, reason: reason))
                    reasons.append("\(slug): suggested, \(reason)")
                } else if raw >= high {
                    let reason = "classifier \(p), reader silent"
                    suggested.append(.init(slug: slug, probability: p, evidence: evidence, reason: reason))
                    reasons.append("\(slug): suggested, \(reason)")
                }
            } else if let reader {
                let reason = "reader \(Self.round(reader.confidence)), no classifier answer"
                suggested.append(.init(slug: slug, probability: Self.round(reader.confidence), evidence: evidence, reason: reason))
                reasons.append("\(slug): suggested, \(reason)")
            }
        }

        // Top `maxTags` by probability apply; the rest wait.
        applied.sort { $0.probability > $1.probability }
        if applied.count > input.maxTags {
            let overflow = applied[input.maxTags...]
            applied = Array(applied.prefix(input.maxTags))
            for a in overflow {
                let reason = "cap of \(input.maxTags) reached"
                suggested.append(.init(slug: a.slug, probability: a.probability, evidence: a.evidence, reason: reason))
                reasons.append("\(a.slug): suggested, \(reason)")
            }
        }
        suggested.sort { $0.probability > $1.probability }

        var unsure = applied.isEmpty
        if !classifier.agree {
            unsure = true
            if let a = classifier.pass1?.choice, let b = classifier.pass2?.choice {
                reasons.append("unsure: the primary mood changed with the option order (\(a) vs \(b))")
            } else {
                reasons.append("unsure: the classifier gave no primary mood")
            }
        }
        return finish(input: input, applied: applied, suggested: suggested, reasons: reasons, unsure: unsure)
    }

    // MARK: p0 (classifier only)

    private static func p0(_ input: PolicyInput) -> PolicyDecision {
        guard let classifier = input.classifier else {
            return PolicyDecision(applied: [], suggested: [], unsure: true, outcome: .none, reasons: ["no classifier answer"])
        }
        var applied: [PolicyDecision.Applied] = []
        var suggested: [PolicyDecision.Suggested] = []
        var reasons: [String] = []
        let byReader = Dictionary(uniqueKeysWithValues: input.candidates.map { ($0.slug, $0) })
        for (slug, raw) in classifier.probabilities.sorted(by: { $0.value > $1.value }) {
            let floor = input.floor(for: slug)
            let p = Self.round(raw)
            let evidence = byReader[slug]?.evidence ?? ""
            if raw >= floor, applied.count < input.maxTags {
                applied.append(.init(slug: slug, probability: p, evidence: evidence))
                reasons.append("\(slug): applied, classifier \(p) ≥ \(floor)")
            } else if raw >= floor - 0.10 {
                let reason = raw >= floor ? "cap of \(input.maxTags) reached" : "classifier \(p) within 0.10 of \(floor)"
                suggested.append(.init(slug: slug, probability: p, evidence: evidence, reason: reason))
                reasons.append("\(slug): suggested, \(reason)")
            }
        }
        return finish(input: input, applied: applied, suggested: suggested, reasons: reasons, unsure: applied.isEmpty || !classifier.agree)
    }

    // MARK: pr (reader only, nothing auto-applies)

    private static func readerOnly(_ input: PolicyInput) -> PolicyDecision {
        var suggested: [PolicyDecision.Suggested] = []
        var reasons: [String] = []
        for candidate in input.candidates.sorted(by: { $0.confidence > $1.confidence }) {
            let p = Self.round(candidate.confidence)
            suggested.append(.init(slug: candidate.slug, probability: p, evidence: candidate.evidence, reason: "reader-only policy"))
            reasons.append("\(candidate.slug): suggested, reader-only policy")
        }
        return finish(input: input, applied: [], suggested: suggested, reasons: reasons, unsure: true)
    }

    // MARK: Shared tail

    private static func finish(input: PolicyInput, applied: [PolicyDecision.Applied], suggested: [PolicyDecision.Suggested], reasons: [String], unsure: Bool) -> PolicyDecision {
        var applied = applied
        var suggested = suggested
        var reasons = reasons
        if input.unverified, !applied.isEmpty {
            for a in applied {
                suggested.insert(.init(slug: a.slug, probability: a.probability, evidence: a.evidence, reason: "story source is model-written (unverified)"), at: 0)
            }
            applied = []
            reasons.append("unverified story source: nothing auto-applies")
        }
        let unsure = unsure || applied.isEmpty
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
