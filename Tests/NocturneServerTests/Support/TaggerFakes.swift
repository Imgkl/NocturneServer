import AsyncHTTPClient
import FluentKit
import Foundation
import HummingbirdFluent
import Logging

@testable import NocturneServer

/// Scripted story source for pipeline tests.
final class ScriptedEnricher: Enriching, @unchecked Sendable {
    var source: EnrichmentSource = .wikipedia
    var textBlock: String? = "# Identity\nTitle: Heat (1995)\n\n# Plot (Wikipedia, full, contains spoilers)\nA thief and a cop."
    var identityJson: String? = nil
    var error: Error? = nil
    private let lock = NSLock()
    private var calls: [String] = []

    var enrichCalls: [String] { lock.withLock { calls } }

    func enrich(jellyfinId: String, item: BaseItemDto?, force: Bool, context: CallContext) async throws -> MovieEnrichment {
        lock.withLock { calls.append(jellyfinId) }
        if let error { throw error }
        let row = MovieEnrichment(jellyfinId: jellyfinId)
        row.source = source.rawValue
        row.unverified = source == .model
        row.plotFound = textBlock != nil && source != .none
        row.textBlock = textBlock
        row.identityJson = identityJson
        row.inputHash = textBlock.map(TextBlockBuilder.sha256Hex)
        row.enrichVersion = TextBlockBuilder.version
        return row
    }
}

/// Scripted reader. Records what it was asked, answers from `answer`, optionally throws, and
/// optionally meters a cost against the decision id so cost summing can be tested.
final class ScriptedReader: Reading, @unchecked Sendable {
    var answer: ReaderAnswer
    var error: Error? = nil
    var model = "claude-haiku-5-5"
    var costPerCall: Double = 0
    let fluent: Fluent?
    private let lock = NSLock()
    private var received: [(textBlock: String, calibration: [String: TagCalibration])] = []

    init(answer: ReaderAnswer, fluent: Fluent? = nil) {
        self.answer = answer
        self.fluent = fluent
    }

    var calls: Int { lock.withLock { received.count } }
    var lastTextBlock: String? { lock.withLock { received.last?.textBlock } }
    var lastCalibration: [String: TagCalibration]? { lock.withLock { received.last?.calibration } }

    func read(textBlock: String, learnedRules: String?, calibration: [String: TagCalibration], apiKey: String, context: CallContext) async throws -> ReaderResult {
        lock.withLock { received.append((textBlock, calibration)) }
        if costPerCall > 0, let fluent {
            try await ApiCall(
                runId: context.runId, decisionId: context.decisionId, provider: "anthropic", endpoint: "/v1/messages",
                model: model, attempt: 1, httpStatus: 200, durationMs: 5, unitsJson: "{}", costUsd: costPerCall
            ).save(on: fluent.db())
        }
        if let error { throw error }
        let raw = String(decoding: try JSONEncoder().encode(answer), as: UTF8.self)
        return ReaderResult(answer: answer, model: model, inputTokens: 100, outputTokens: 50, cacheReadTokens: 9000, cacheWriteTokens: 0, rawJson: raw)
    }
}

final class ScriptedClassifier: DecisionClassifying, @unchecked Sendable {
    let provider = "typesafe"
    var answer: ClassifierAnswer
    var error: Error? = nil
    private let lock = NSLock()
    private var received: [(textBlock: String, guide: String?)] = []

    init(answer: ClassifierAnswer) {
        self.answer = answer
    }

    var calls: Int { lock.withLock { received.count } }
    var lastGuide: String?? { lock.withLock { received.last?.guide } }

    func classify(textBlock: String, guide: String?, jellyfinId: String, apiKey: String, context: CallContext) async throws -> ClassifierAnswer {
        lock.withLock { received.append((textBlock, guide)) }
        if let error { throw error }
        return answer
    }
}

func classifierAnswer(_ probabilities: [String: Double], primary: String? = nil, secondPick: String? = nil) -> ClassifierAnswer {
    let pick = primary ?? probabilities.max { $0.value < $1.value }?.key ?? "none"
    let pass1 = ClassifierChoice(choice: pick, probabilities: probabilities, confidence: 0.9)
    let pass2 = ClassifierChoice(choice: secondPick ?? pick, probabilities: probabilities, confidence: 0.9)
    return ClassifierAnswer(provider: "typesafe", model: "jev-1.13.0", probabilities: probabilities, pass1: pass1, pass2: pass2, rawJson: "{\"answers\":{}}", inputTokens: 12_000)
}

/// A MovieService over the test database. Jellyfin is never reached by the tag paths.
func makeMovieService(_ fluent: Fluent, config: NocturneConfiguration) -> MovieService {
    let jellyfin = JellyfinService(baseURL: "http://127.0.0.1:1", apiKey: "", userId: "", httpClient: HTTPClient.shared)
    return MovieService(config: config, fluent: fluent, jellyfinService: jellyfin)
}

func makePipeline(
    _ fluent: Fluent, config: NocturneConfiguration, enricher: ScriptedEnricher, reader: ScriptedReader,
    apiKey: String? = "sk-test", budgetCap: String? = nil, classifier: ScriptedClassifier? = nil, jevKey: String? = "jev-test"
) async throws -> (pipeline: TaggerPipeline, movies: MovieService, settings: SettingsStore) {
    let settings = SettingsStore(db: fluent.db(), logger: Logger(label: "test"))
    try await settings.ensureTable()
    if let apiKey { try await settings.set(TaggerPipeline.apiKeySetting, apiKey) }
    if let budgetCap { try await settings.set(BudgetGuard.settingKey, budgetCap) }
    if classifier != nil {
        try await settings.set(PolicyConfig.providerSetting, "jev")
        if let jevKey { try await settings.set(JevClient.apiKeySetting, jevKey) }
    }
    let movies = makeMovieService(fluent, config: config)
    let pipeline = TaggerPipeline(
        fluent: fluent, config: config, enrichment: enricher, reader: reader, classifier: classifier, movies: movies,
        budget: BudgetGuard(fluent: fluent, settings: settings), settings: settings,
        titles: { [:] }, logger: Logger(label: "test"))
    return (pipeline, movies, settings)
}

func candidate(_ slug: String, _ confidence: Double, evidence: String = "ev") -> ReaderCandidate {
    ReaderCandidate(slug: slug, evidence: evidence, confidence: confidence)
}

func answer(_ candidates: [ReaderCandidate], residue: String = "A quiet ache.") -> ReaderAnswer {
    ReaderAnswer(residue: residue, candidates: candidates, alternates: [])
}

/// A film's tag with its label source, comparable to a `"slug:source"` literal in tests.
struct TagRow: Equatable, ExpressibleByStringLiteral {
    let slug: String
    let source: String
    init(slug: String, source: String) { self.slug = slug; self.source = source }
    init(stringLiteral value: String) {
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        self.slug = parts[0]
        self.source = parts.count > 1 ? parts[1] : ""
    }
}

func tagSlugs(_ fluent: Fluent, _ jellyfinId: String) async throws -> [TagRow] {
    guard let movie = try await Movie.query(on: fluent.db()).filter(\.$jellyfinId == jellyfinId).first() else { return [] }
    let rows = try await MovieTag.query(on: fluent.db()).filter(\.$movie.$id == movie.requireID()).with(\.$tag).all()
    return rows.map { TagRow(slug: $0.tag.slug, source: $0.labelSource) }.sorted { $0.slug < $1.slug }
}
