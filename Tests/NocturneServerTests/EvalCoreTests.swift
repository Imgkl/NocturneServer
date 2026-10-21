import Foundation
import Testing

@testable import NocturneServer

@Suite struct EvalCoreTests {
    private let config = NocturneConfiguration()

    private func film(_ id: String, positives: Set<String> = [], negatives: Set<String> = [], reader: [String: Double] = [:], classifier: [String: Double] = [:]) -> EvalFilm {
        EvalFilm(jellyfinId: id, title: id, positives: positives, negatives: negatives, reader: reader, classifier: classifier)
    }

    @Test func wilsonLowerBound() {
        #expect(EvalCore.wilsonLower(correct: 0, n: 0) == 0)
        #expect(abs(EvalCore.wilsonLower(correct: 10, n: 10) - 0.722) < 0.001)
        #expect(abs(EvalCore.wilsonLower(correct: 9, n: 10) - 0.596) < 0.001)
        #expect(abs(EvalCore.wilsonLower(correct: 50, n: 50) - 0.929) < 0.001)
        #expect(abs(EvalCore.wilsonLower(correct: 0, n: 10)) < 1e-9)
    }

    @Test func appliesPerVersion() {
        let f = film("a", reader: ["ha-ha-ha": 0.9], classifier: ["ha-ha-ha": 0.75, "cult-chaos": 0.95])
        #expect(EvalCore.applies(version: "p1", film: f, slug: "ha-ha-ha", floor: 0.7))
        #expect(!EvalCore.applies(version: "p1", film: f, slug: "ha-ha-ha", floor: 0.8))
        #expect(!EvalCore.applies(version: "p1", film: f, slug: "cult-chaos", floor: 0.5))  // reader silent
        #expect(EvalCore.applies(version: "p0", film: f, slug: "cult-chaos", floor: 0.9))
        #expect(EvalCore.applies(version: "p-legacy", film: f, slug: "ha-ha-ha", floor: 0.85))
        #expect(!EvalCore.applies(version: "p-legacy", film: f, slug: "cult-chaos", floor: 0.1))
        #expect(!EvalCore.applies(version: "pr", film: f, slug: "ha-ha-ha", floor: 0.0))
        #expect(!EvalCore.applies(version: "p1", film: film("b", reader: ["ha-ha-ha": 0.9]), slug: "ha-ha-ha", floor: 0.1))  // no classifier
    }

    @Test func metricsCountOnlyJudgedFilms() {
        let films = [
            film("yes1", positives: ["ha-ha-ha"], reader: ["ha-ha-ha": 0.9], classifier: ["ha-ha-ha": 0.9]),
            film("yes2", positives: ["ha-ha-ha"], reader: ["ha-ha-ha": 0.9], classifier: ["ha-ha-ha": 0.6]),  // missed at 0.7
            film("no1", negatives: ["ha-ha-ha"], reader: ["ha-ha-ha": 0.8], classifier: ["ha-ha-ha": 0.8]),   // wrong at 0.7
            film("unknown", reader: ["ha-ha-ha": 0.9], classifier: ["ha-ha-ha": 0.99]),                       // not judged: ignored
        ]
        let m = EvalCore.metrics(version: "p1", films: films, slug: "ha-ha-ha", floor: 0.7)
        #expect(m.applied == 2 && m.correct == 1 && m.wrong == 1)
        #expect(m.precision == 0.5)
        #expect(m.recall == 0.5)
        let strict = EvalCore.metrics(version: "p1", films: films, slug: "ha-ha-ha", floor: 0.85)
        #expect(strict.applied == 1 && strict.correct == 1 && strict.precision == 1.0 && strict.recall == 0.5)
        let none = EvalCore.metrics(version: "p1", films: films, slug: "cult-chaos", floor: 0.5)
        #expect(none.applied == 0 && none.precision == nil && none.recall == nil)
    }

    @Test func suggestedFloorIsTheLowestThatClearsTheTargetWithEnoughFilms() {
        // Twelve confirmed films at 0.8 and above, three rejected ones at 0.6.
        var films: [EvalFilm] = []
        for i in 0..<12 { films.append(film("y\(i)", positives: ["ha-ha-ha"], reader: ["ha-ha-ha": 0.9], classifier: ["ha-ha-ha": 0.8 + Double(i % 3) * 0.05])) }
        for i in 0..<3 { films.append(film("n\(i)", negatives: ["ha-ha-ha"], reader: ["ha-ha-ha": 0.9], classifier: ["ha-ha-ha": 0.6])) }
        let grid = EvalCore.grid.map { EvalCore.metrics(version: "p1", films: films, slug: "ha-ha-ha", floor: $0) }
        #expect(EvalCore.grid.first == 0.5 && EvalCore.grid.last == 0.9 && EvalCore.grid.count == 9)
        // At 0.50 to 0.60 the three rejections apply: 12 of 15, Wilson lower about 0.55.
        #expect(grid[0].applied == 15 && grid[0].correct == 12)
        // At 0.65 and above only the twelve confirmed apply: Wilson lower about 0.76.
        #expect(grid[3].applied == 12 && grid[3].correct == 12)
        #expect(EvalCore.suggestedFloor(grid: grid, target: 0.75) == 0.65)
        #expect(EvalCore.suggestedFloor(grid: grid, target: 0.99) == nil)
        // Too few films at a floor never counts as evidence.
        let thin = EvalCore.grid.map { EvalCore.metrics(version: "p1", films: Array(films.prefix(3)), slug: "ha-ha-ha", floor: $0) }
        #expect(EvalCore.suggestedFloor(grid: thin, target: 0.5) == nil)
    }

    @Test func brierNeedsEnoughJudgedFilms() {
        var films: [EvalFilm] = []
        for i in 0..<5 { films.append(film("y\(i)", positives: ["ha-ha-ha"], classifier: ["ha-ha-ha": 0.9])) }
        #expect(abs((EvalCore.brier(films: films, slug: "ha-ha-ha") ?? -1) - 0.01) < 1e-9)
        #expect(EvalCore.brier(films: Array(films.prefix(4)), slug: "ha-ha-ha") == nil)
        films.append(film("n", negatives: ["ha-ha-ha"], classifier: ["ha-ha-ha": 0.9]))
        #expect(abs((EvalCore.brier(films: films, slug: "ha-ha-ha") ?? -1) - (0.05 + 0.81) / 6) < 1e-9)
    }

    @Test func reportCarriesEveryMoodVersionsAndSuggestedFloors() throws {
        var films: [EvalFilm] = []
        for i in 0..<10 { films.append(film("y\(i)", positives: ["ha-ha-ha"], reader: ["ha-ha-ha": 0.9], classifier: ["ha-ha-ha": 0.9])) }
        for i in 0..<10 { films.append(film("n\(i)", negatives: ["ha-ha-ha"], reader: ["ha-ha-ha": 0.9], classifier: ["ha-ha-ha": 0.55])) }
        let policy = PolicyConfig.defaults(slugs: config.moodBuckets.keys)
        let report = EvalCore.report(films: films, buckets: config.moodBuckets, policy: policy, target: 0.70, now: Date(timeIntervalSince1970: 0))
        #expect(report.moods.count == 36)
        #expect(report.films == 20 && report.positives == 10 && report.negatives == 10)
        #expect(report.policyVersion == "p1")
        let haha = try #require(report.moods.first { $0.slug == "ha-ha-ha" })
        #expect(haha.currentFloor == 0.80)
        #expect(haha.current.applied == 10 && haha.current.correct == 10)
        #expect(haha.suggestedFloor == 0.60)
        #expect(haha.brier != nil)
        #expect(report.overall.applied == 10 && report.overall.filmsWithApplied == 10)
        // p-legacy at the reader's own confidence applies the mood to every film, half of them wrong.
        #expect(report.versions["p-legacy"]?.applied == 20 && report.versions["p-legacy"]?.correct == 10)
        #expect(report.versions["p0"]?.applied == 10)
        #expect(report.generatedAt == "1970-01-01T00:00:00Z")
        let json = EvalService.json(report)
        #expect(json.contains("\"suggestedFloor\":0.6"))
        let back = try JSONDecoder().decode(EvalReport.self, from: Data(json.utf8))
        #expect(back == report)
    }
}
