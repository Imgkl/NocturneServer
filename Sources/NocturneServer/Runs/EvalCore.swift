import Foundation

/// One labelled film as the eval sees it: what the owner said, and what the models said about it.
struct EvalFilm: Sendable, Equatable {
    let jellyfinId: String
    let title: String
    /// Moods the owner confirmed on the film.
    let positives: Set<String>
    /// Moods the owner saw proposed and did not take.
    let negatives: Set<String>
    /// The reader's confidence per mood it named.
    let reader: [String: Double]
    /// The classifier's probability per mood; empty when none ran for the film.
    let classifier: [String: Double]

    func judged(_ slug: String) -> Bool { positives.contains(slug) || negatives.contains(slug) }
}

/// Precision and recall of one mood at one floor, counted over judged films only: a film the
/// owner never judged for the mood cannot be right or wrong.
struct EvalMetrics: Codable, Sendable, Equatable {
    let floor: Double
    let applied: Int
    let correct: Int
    let wrong: Int
    let precision: Double?
    let wilsonLower: Double?
    let recall: Double?
}

struct EvalMoodReport: Codable, Sendable, Equatable {
    let slug: String
    let title: String
    let positives: Int
    let negatives: Int
    let currentFloor: Double
    let current: EvalMetrics
    let grid: [EvalMetrics]
    /// The lowest floor on the grid whose Wilson lower bound reaches the target with enough
    /// applied films; nil when none does.
    let suggestedFloor: Double?
    /// Calibration of the classifier's probability against the owner's label, lower is better.
    let brier: Double?
}

struct EvalOverall: Codable, Sendable, Equatable {
    let applied: Int
    let correct: Int
    let wrong: Int
    let precision: Double?
    let wilsonLower: Double?
    /// Films where at least one mood applies, out of the labelled films.
    let filmsWithApplied: Int
    let films: Int
}

struct EvalReport: Codable, Sendable, Equatable {
    let generatedAt: String
    let policyVersion: String
    let targetPrecision: Double
    let films: Int
    let positives: Int
    let negatives: Int
    let moods: [EvalMoodReport]
    let overall: EvalOverall
    /// The same policy with every suggested floor adopted.
    let overallAtSuggested: EvalOverall
    /// Every policy version at the current floors, side by side.
    let versions: [String: EvalOverall]
}

/// The replay: pure functions over stored answers, no model call, so the floors come from the
/// owner's labels rather than from guesses.
enum EvalCore {
    static let grid: [Double] = stride(from: 0.50, through: 0.90, by: 0.05).map { ($0 * 100).rounded() / 100 }
    static let minimumApplied = 5
    static let minimumJudgedForBrier = 5

    /// Wilson score interval, lower bound, z = 1.96 for 95%.
    static func wilsonLower(correct: Int, n: Int, z: Double = 1.96) -> Double {
        guard n > 0 else { return 0 }
        let p = Double(correct) / Double(n)
        let nn = Double(n)
        let centre = p + (z * z) / (2 * nn)
        let spread = z * ((p * (1 - p)) / nn + (z * z) / (4 * nn * nn)).squareRoot()
        return (centre - spread) / (1 + (z * z) / nn)
    }

    /// Whether the policy version applies `slug` to the film at `floor`, mood by mood (the
    /// five-tag cap is left out of the replay).
    static func applies(version: String, film: EvalFilm, slug: String, floor: Double) -> Bool {
        switch version {
        case PolicyEngine.p1Version:
            guard film.reader[slug] != nil, let p = film.classifier[slug] else { return false }
            return p >= floor
        case PolicyEngine.p0Version:
            guard let p = film.classifier[slug] else { return false }
            return p >= floor
        case PolicyEngine.legacyVersion:
            guard let c = film.reader[slug] else { return false }
            return c >= floor
        default:
            return false
        }
    }

    static func metrics(version: String, films: [EvalFilm], slug: String, floor: Double) -> EvalMetrics {
        var applied = 0
        var correct = 0
        var wrong = 0
        var positives = 0
        for film in films {
            let positive = film.positives.contains(slug)
            if positive { positives += 1 }
            guard film.judged(slug), applies(version: version, film: film, slug: slug, floor: floor) else { continue }
            applied += 1
            if positive { correct += 1 } else { wrong += 1 }
        }
        return EvalMetrics(
            floor: floor, applied: applied, correct: correct, wrong: wrong,
            precision: applied > 0 ? Double(correct) / Double(applied) : nil,
            wilsonLower: applied > 0 ? wilsonLower(correct: correct, n: applied) : nil,
            recall: positives > 0 ? Double(correct) / Double(positives) : nil)
    }

    static func brier(films: [EvalFilm], slug: String) -> Double? {
        var sum = 0.0
        var n = 0
        for film in films where film.judged(slug) {
            guard let p = film.classifier[slug] else { continue }
            let y = film.positives.contains(slug) ? 1.0 : 0.0
            sum += (p - y) * (p - y)
            n += 1
        }
        return n >= minimumJudgedForBrier ? sum / Double(n) : nil
    }

    static func suggestedFloor(grid: [EvalMetrics], target: Double) -> Double? {
        grid.first { ($0.wilsonLower ?? 0) >= target && $0.applied >= minimumApplied }?.floor
    }

    static func overall(version: String, films: [EvalFilm], floors: [String: Double], slugs: [String], defaultFloor: Double) -> EvalOverall {
        var applied = 0
        var correct = 0
        var wrong = 0
        var filmsWithApplied = 0
        for film in films {
            var any = false
            for slug in slugs {
                let floor = floors[slug] ?? defaultFloor
                guard applies(version: version, film: film, slug: slug, floor: floor) else { continue }
                any = true
                guard film.judged(slug) else { continue }
                applied += 1
                if film.positives.contains(slug) { correct += 1 } else { wrong += 1 }
            }
            if any { filmsWithApplied += 1 }
        }
        return EvalOverall(
            applied: applied, correct: correct, wrong: wrong,
            precision: applied > 0 ? Double(correct) / Double(applied) : nil,
            wilsonLower: applied > 0 ? wilsonLower(correct: correct, n: applied) : nil,
            filmsWithApplied: filmsWithApplied, films: films.count)
    }

    static func report(films: [EvalFilm], buckets: [String: MoodBucket], policy: PolicyConfig, target: Double = 0.85, now: Date = Date()) -> EvalReport {
        let slugs = buckets.keys.sorted()
        let version = policy.version
        var moods: [EvalMoodReport] = []
        var suggested = policy.floors
        for slug in slugs {
            let currentFloor = policy.floors[slug] ?? PolicyConfig.defaultFloor
            let gridMetrics = grid.map { metrics(version: version, films: films, slug: slug, floor: $0) }
            let suggestedFloor = suggestedFloor(grid: gridMetrics, target: target)
            if let suggestedFloor { suggested[slug] = suggestedFloor }
            moods.append(EvalMoodReport(
                slug: slug, title: buckets[slug]?.title ?? slug,
                positives: films.filter { $0.positives.contains(slug) }.count,
                negatives: films.filter { $0.negatives.contains(slug) }.count,
                currentFloor: currentFloor,
                current: metrics(version: version, films: films, slug: slug, floor: currentFloor),
                grid: gridMetrics,
                suggestedFloor: suggestedFloor,
                brier: brier(films: films, slug: slug)))
        }
        var versions: [String: EvalOverall] = [:]
        for v in [PolicyEngine.p1Version, PolicyEngine.p0Version, PolicyEngine.legacyVersion] {
            versions[v] = overall(version: v, films: films, floors: policy.floors, slugs: slugs, defaultFloor: PolicyConfig.defaultFloor)
        }
        let formatter = ISO8601DateFormatter()
        return EvalReport(
            generatedAt: formatter.string(from: now),
            policyVersion: version,
            targetPrecision: target,
            films: films.count,
            positives: films.reduce(0) { $0 + $1.positives.count },
            negatives: films.reduce(0) { $0 + $1.negatives.count },
            moods: moods,
            overall: overall(version: version, films: films, floors: policy.floors, slugs: slugs, defaultFloor: PolicyConfig.defaultFloor),
            overallAtSuggested: overall(version: version, films: films, floors: suggested, slugs: slugs, defaultFloor: PolicyConfig.defaultFloor),
            versions: versions)
    }
}
