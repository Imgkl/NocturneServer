import FluentKit
import Foundation
import HummingbirdFluent
import Logging

/// Loads the owner's labels and the stored answers, runs the replay, keeps the latest report,
/// and writes the suggested floors into the policy when the owner accepts them.
final class EvalService: @unchecked Sendable {
    static let latestSetting = "eval.latest"
    static let targetSetting = "eval.target_precision"

    let fluent: Fluent
    let config: NocturneConfiguration
    let settings: SettingsStore
    let runService: RunService
    let logger: Logger

    init(fluent: Fluent, config: NocturneConfiguration, settings: SettingsStore, runService: RunService, logger: Logger = Logger(label: "Eval")) {
        self.fluent = fluent
        self.config = config
        self.settings = settings
        self.runService = runService
        self.logger = logger
    }

    // MARK: Labels

    /// Every film the owner judged: confirmed moods are positives; moods proposed in a row the
    /// owner resolved and did not take are negatives. Auto-sourced rows are never ground truth.
    func labelledFilms() async throws -> [EvalFilm] {
        let db = fluent.db()
        var positives: [String: Set<String>] = [:]
        let userTags = try await MovieTag.query(on: db).filter(\.$labelSource == LabelSource.user.rawValue).with(\.$tag).with(\.$movie).all()
        for row in userTags {
            positives[row.movie.jellyfinId, default: []].insert(row.tag.slug)
        }
        var negatives: [String: Set<String>] = [:]
        let resolved = try await TagSuggestion.query(on: db).filter(\.$resolvedBy == ResolvedBy.user).all()
        for row in resolved {
            let kept = positives[row.jellyfinId] ?? []
            let rejected: Set<String>
            if row.kind == TaggerPipeline.regradeKind {
                let items = ReviewQueue.items(of: row)
                if row.status == "rejected" {
                    // The owner undid the regrade: what it added was wrong; what it wanted dropped stays unjudged.
                    rejected = Set(items.filter { $0.kind == .add && $0.applied && $0.reason == TaggerPipeline.addedOnRegrade }.map(\.slug)).subtracting(kept)
                } else {
                    // The owner took the new decision: the moods it dropped, and the proposals not kept, are wrong.
                    rejected = Set(Self.proposedSlugs(in: row)).union(items.filter { $0.kind == .remove }.map(\.slug)).subtracting(kept)
                }
            } else {
                let proposed = Set(Self.proposedSlugs(in: row))
                guard !proposed.isEmpty else { continue }
                rejected = row.status == "rejected" ? proposed : proposed.subtracting(kept)
            }
            if !rejected.isEmpty { negatives[row.jellyfinId, default: []].formUnion(rejected) }
        }
        let ids = Set(positives.keys).union(negatives.keys)
        guard !ids.isEmpty else { return [] }

        let movies = try await Movie.query(on: db).filter(\.$jellyfinId ~~ Array(ids)).all()
        let decisionIds = movies.compactMap(\.currentDecisionId)
        var decisions: [Decision] = []
        if !decisionIds.isEmpty {
            decisions = try await Decision.query(on: db).filter(\.$id ~~ decisionIds).all()
        }
        var decisionById: [UUID: Decision] = [:]
        for d in decisions { if let id = d.id { decisionById[id] = d } }
        var titles: [String: String] = [:]
        for row in try await MovieEnrichment.query(on: db).all() where ids.contains(row.jellyfinId) {
            titles[row.jellyfinId] = Self.title(of: row)
        }
        let known = Set(config.moodBuckets.keys)
        let order1 = config.moodBuckets.keys.sorted() + [JevClient.noneOption]

        var films: [EvalFilm] = []
        for movie in movies {
            var reader: [String: Double] = [:]
            var classifier: [String: Double] = [:]
            if let id = movie.currentDecisionId, let decision = decisionById[id] {
                if let json = decision.readerJson, let answer = try? ReaderService.parse(json, knownSlugs: known, maxTags: config.maxAutoTags, logger: logger) {
                    for c in answer.candidates { reader[c.slug] = c.confidence }
                }
                if let json = decision.classifierJson, let response = try? JSONDecoder().decode(JevClient.Response.self, from: Data(json.utf8)) {
                    classifier = JevClient.parse(response, buckets: config.moodBuckets, order1: order1, provider: decision.classifierProvider ?? "typesafe", fallbackModel: "", rawJson: "").probabilities
                }
            }
            films.append(EvalFilm(
                jellyfinId: movie.jellyfinId, title: titles[movie.jellyfinId] ?? movie.jellyfinId,
                positives: positives[movie.jellyfinId] ?? [], negatives: negatives[movie.jellyfinId] ?? [],
                reader: reader, classifier: classifier))
        }
        return films.sorted { $0.title < $1.title }
    }

    static func proposedSlugs(in row: TagSuggestion) -> [String] {
        var slugs = row.suggestedTags
        if let json = row.itemsJson, let items = try? JSONDecoder().decode([SuggestionItem].self, from: Data(json.utf8)) {
            slugs += items.filter { $0.kind == .add }.map(\.slug)
        }
        var seen = Set<String>()
        return slugs.filter { seen.insert($0).inserted }
    }

    static func title(of row: MovieEnrichment) -> String {
        guard let json = row.identityJson, let identity = try? JSONDecoder().decode(EnrichmentService.Identity.self, from: Data(json.utf8)) else { return row.jellyfinId }
        return identity.title
    }

    // MARK: Runs

    func target() async throws -> Double {
        Double(try await settings.get(Self.targetSetting) ?? "") ?? 0.85
    }

    /// Replays the current policy over the labelled films and keeps the report as the latest.
    @discardableResult
    func run(trigger: RunTrigger) async throws -> EvalReport {
        let films = try await labelledFilms()
        let policy = try await PolicyConfig.load(settings: settings, slugs: config.moodBuckets.keys)
        let run = try await runService.start(kind: .eval, trigger: trigger, total: films.count, params: ["policy": policy.version])
        let report = EvalCore.report(films: films, buckets: config.moodBuckets, policy: policy, target: try await target())
        try await settings.set(Self.latestSetting, Self.json(report))
        let stats: [String: Int] = [
            "films": report.films, "positives": report.positives, "negatives": report.negatives,
            "applied": report.overall.applied, "correct": report.overall.correct,
            "suggested_floors": report.moods.filter { $0.suggestedFloor != nil }.count,
        ]
        try await runService.tick(try run.requireID(), processed: films.count, stats: stats)
        try await runService.finish(try run.requireID(), status: .done, stats: stats)
        logger.info("eval: \(report.films) films, \(report.overall.applied) applied over judged moods, precision \(report.overall.precision.map { String(format: "%.3f", $0) } ?? "-")")
        return report
    }

    func latest() async throws -> EvalReport? {
        guard let json = try await settings.get(Self.latestSetting), !json.isEmpty else { return nil }
        return try? JSONDecoder().decode(EvalReport.self, from: Data(json.utf8))
    }

    /// Writes every suggested floor from the latest report into the policy and returns the floors.
    func acceptSuggestedFloors() async throws -> [String: Double] {
        guard let report = try await latest() else { return [:] }
        let policy = try await PolicyConfig.load(settings: settings, slugs: config.moodBuckets.keys)
        var floors = policy.floors
        for mood in report.moods {
            if let suggested = mood.suggestedFloor { floors[mood.slug] = suggested }
        }
        try await settings.set(PolicyConfig.floorsSetting, PolicyConfig.encode(floors))
        return floors
    }

    static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
