import FluentKit
import Foundation
import HummingbirdFluent
import Logging

/// Teach: the films where the owner and the system disagree, grouped by the boundary between two
/// moods, one tap per film, then rules written from the answers into the guide.
final class TeachService: @unchecked Sendable {
    /// The close pairs from the guide's disambiguation rule, in display order.
    static let pairs: [(String, String)] = [
        ("bittersweet-aftermath", "emotional-gut-punch"),
        ("bittersweet-aftermath", "rainy-day-rewinds"),
        ("ha-ha-ha", "rainy-day-rewinds"),
        ("one-room-pressure-cooker", "psychological-pressure-cooker"),
        ("psychological-pressure-cooker", "horror-and-unease"),
        ("the-twist-is-the-plot", "brainmelt-zone"),
        ("brainmelt-zone", "time-twists"),
        ("horror-and-unease", "uncanny-vibes"),
        ("uncanny-vibes", "late-night-mind-rattle"),
        ("late-night-mind-rattle", "wtf-did-i-watch"),
        ("vibe-is-the-plot", "visual-worship"),
        ("film-school-shelf", "modern-masterpieces"),
        ("regional-gems", "underseen-treasures"),
        ("crime-grit-style", "obsidian-noir"),
        ("crime-grit-style", "antihero-study"),
        ("antihero-study", "cat-and-mouse"),
        ("men-with-vibes", "crime-grit-style"),
        ("coming-of-age", "feel-good-romance"),
    ]

    struct Boundary: Codable, Sendable, Equatable {
        let key: String
        let left: String
        let right: String

        init(_ a: String, _ b: String) {
            if let pair = TeachService.pairs.first(where: { ($0.0 == a && $0.1 == b) || ($0.0 == b && $0.1 == a) }) {
                left = pair.0
                right = pair.1
            } else {
                left = min(a, b)
                right = max(a, b)
            }
            key = "\(left)|\(right)"
        }

        init?(key: String) {
            let parts = key.split(separator: "|").map(String.init)
            guard parts.count == 2, parts[0] != parts[1] else { return nil }
            self.init(parts[0], parts[1])
        }

        static func isKnown(_ a: String, _ b: String) -> Bool {
            TeachService.pairs.contains { ($0.0 == a && $0.1 == b) || ($0.0 == b && $0.1 == a) }
        }
    }

    struct Film: Codable, Sendable, Equatable {
        let jellyfinId: String
        let title: String
        let residue: String?
        let leftProbability: Double?
        let rightProbability: Double?
        let systemPick: String?
        let adminPick: String?
        /// The owner's answer for this boundary, when given: the left slug, the right slug, or `neither`.
        let answer: String?
        /// Who the probabilities come from: `classifier` (the grader) or `reader` (AI's own confidence).
        var probabilitySource: String? = nil
    }

    struct Group: Codable, Sendable, Equatable {
        let boundary: Boundary
        let leftTitle: String
        let rightTitle: String
        let films: [Film]
        let answered: Int
        /// Rules already learned for this boundary.
        let rules: [String]
    }

    struct Accepted: Codable, Sendable {
        let guideVersion: Int
        let rules: Int
        let regradeStarted: Bool
        let regradeFilms: Int
    }

    let fluent: Fluent
    let config: NocturneConfiguration
    let settings: SettingsStore
    let anthropic: AnthropicClient
    let backfill: BackfillJob
    let logger: Logger

    init(fluent: Fluent, config: NocturneConfiguration, settings: SettingsStore, anthropic: AnthropicClient, backfill: BackfillJob, logger: Logger = Logger(label: "Teach")) {
        self.fluent = fluent
        self.config = config
        self.settings = settings
        self.anthropic = anthropic
        self.backfill = backfill
        self.logger = logger
    }

    // MARK: Boundaries

    /// The boundary a disagreement sits on: a known pair between the system's pick and the
    /// owner's mood when there is one, else the classifier's top two moods, else the reader's.
    static func boundary(systemApplied: [String], adminMoods: Set<String>, classifier: [String: Double], reader: [String: Double]) -> Boundary? {
        let extra = adminMoods.subtracting(systemApplied)
        for s in systemApplied {
            for a in extra.sorted() where Boundary.isKnown(s, a) {
                return Boundary(s, a)
            }
        }
        if let s = systemApplied.first, let a = extra.sorted().first {
            return Boundary(s, a)
        }
        let byClassifier = classifier.sorted { $0.value > $1.value }.map(\.key)
        if byClassifier.count >= 2 {
            return Boundary(byClassifier[0], byClassifier[1])
        }
        let byReader = reader.sorted { $0.value > $1.value }.map(\.key)
        if byReader.count >= 2 {
            return Boundary(byReader[0], byReader[1])
        }
        return nil
    }

    // MARK: Candidates

    func groups() async throws -> [Group] {
        let db = fluent.db()
        let movies = try await Movie.query(on: db).all().filter { $0.currentDecisionId != nil }
        let decisionIds = movies.compactMap(\.currentDecisionId)
        var decisionById: [UUID: Decision] = [:]
        if !decisionIds.isEmpty {
            for d in try await Decision.query(on: db).filter(\.$id ~~ decisionIds).all() {
                if let id = d.id { decisionById[id] = d }
            }
        }
        var adminMoods: [String: Set<String>] = [:]
        for row in try await MovieTag.query(on: db).filter(\.$labelSource == LabelSource.user.rawValue).with(\.$tag).with(\.$movie).all() {
            adminMoods[row.movie.jellyfinId, default: []].insert(row.tag.slug)
        }
        var answers: [String: [String: String]] = [:]
        for a in try await TeachAnswer.query(on: db).all() {
            answers[a.jellyfinId, default: [:]][a.boundary] = a.answer
        }
        var titles: [String: String] = [:]
        for row in try await MovieEnrichment.query(on: db).all() {
            titles[row.jellyfinId] = EvalService.title(of: row)
        }
        let learned = try await GuideStore.learned(settings: settings)
        let known = Set(config.moodBuckets.keys)
        let order1 = config.moodBuckets.keys.sorted() + [JevClient.noneOption]

        var filmsByBoundary: [String: [Film]] = [:]
        for movie in movies {
            guard let id = movie.currentDecisionId, let decision = decisionById[id] else { continue }
            let applied = ((try? JSONDecoder().decode([PolicyDecision.Applied].self, from: Data(decision.appliedJson.utf8))) ?? []).map(\.slug)
            let admin = adminMoods[movie.jellyfinId] ?? []
            let disagree = !admin.isEmpty && admin != Set(applied)
            // Unsure means the grader's two passes disagreed or nothing was applied. A film with a
            // suggestion below the floor is only a review row; the tray already covers it.
            guard disagree || decision.unsure else { continue }

            var reader: [String: Double] = [:]
            var residue: String? = nil
            if let json = decision.readerJson, let answer = try? ReaderService.parse(json, knownSlugs: known, maxTags: config.maxAutoTags, logger: logger) {
                for c in answer.candidates { reader[c.slug] = c.confidence }
                residue = answer.residue
            }
            var classifier: [String: Double] = [:]
            if let json = decision.classifierJson, let response = try? JSONDecoder().decode(JevClient.Response.self, from: Data(json.utf8)) {
                classifier = JevClient.parse(response, buckets: config.moodBuckets, order1: order1, provider: decision.classifierProvider ?? "typesafe", fallbackModel: "", rawJson: "").probabilities
            }
            guard let boundary = Self.boundary(systemApplied: applied, adminMoods: admin, classifier: classifier, reader: reader) else { continue }
            let probability: (String) -> Double? = { slug in classifier[slug] ?? reader[slug] }
            filmsByBoundary[boundary.key, default: []].append(Film(
                jellyfinId: movie.jellyfinId,
                title: titles[movie.jellyfinId] ?? movie.jellyfinId,
                residue: residue,
                leftProbability: probability(boundary.left),
                rightProbability: probability(boundary.right),
                systemPick: applied.first,
                adminPick: admin.first { $0 == boundary.left || $0 == boundary.right },
                answer: answers[movie.jellyfinId]?[boundary.key],
                probabilitySource: !classifier.isEmpty ? "classifier" : (reader.isEmpty ? nil : "reader")))
        }

        var groups: [Group] = []
        for (key, films) in filmsByBoundary {
            guard let boundary = Boundary(key: key) else { continue }
            let sorted = films.sorted { ($0.answer == nil ? 0 : 1, $0.title) < ($1.answer == nil ? 0 : 1, $1.title) }
            groups.append(Group(
                boundary: boundary,
                leftTitle: config.moodBuckets[boundary.left]?.title ?? boundary.left,
                rightTitle: config.moodBuckets[boundary.right]?.title ?? boundary.right,
                films: sorted,
                answered: films.filter { $0.answer != nil }.count,
                rules: learned.filter { $0.boundary == key }.map(\.text)))
        }
        return groups.sorted { ($1.films.count - $1.answered, $0.boundary.key) < ($0.films.count - $0.answered, $1.boundary.key) }
    }

    // MARK: Answers

    @discardableResult
    func answer(jellyfinId: String, boundaryKey: String, answer: String) async throws -> TeachAnswer {
        guard let boundary = Boundary(key: boundaryKey) else { throw TeachError.badBoundary(boundaryKey) }
        guard answer == boundary.left || answer == boundary.right || answer == "neither" else { throw TeachError.badAnswer(answer) }
        let db = fluent.db()
        let movie = try await Movie.query(on: db).filter(\.$jellyfinId == jellyfinId).first()
        guard movie != nil else { throw TaggerError.movieNotFound(jellyfinId) }
        if let existing = try await TeachAnswer.query(on: db).filter(\.$jellyfinId == jellyfinId).filter(\.$boundary == boundary.key).first() {
            existing.answer = answer
            try await existing.save(on: db)
            return existing
        }
        let row = TeachAnswer(jellyfinId: jellyfinId, boundary: boundary.key, answer: answer, decisionId: movie?.currentDecisionId)
        try await row.save(on: db)
        return row
    }

    // MARK: Rules

    static let minimumAnswers = 3
    static let maxRules = 3

    /// The strong model reads the two moods, the manual guide and the answered films, and writes
    /// up to three rules that explain the answers without contradicting the guide.
    func previewRules(boundaryKey: String, apiKey: String, context: CallContext = .none) async throws -> [String] {
        guard let boundary = Boundary(key: boundaryKey) else { throw TeachError.badBoundary(boundaryKey) }
        let group = try await groups().first { $0.boundary.key == boundary.key }
        let answered = (group?.films ?? []).filter { $0.answer != nil }
        guard answered.count >= Self.minimumAnswers else { throw TeachError.notEnoughAnswers(answered.count, Self.minimumAnswers) }
        let manual = try await GuideStore.manual(settings: settings, fallback: config.autoTaggingPrompt)
        let model = try await settings.get(FallbackSynopsisService.modelSetting).flatMap { $0.isEmpty ? nil : $0 } ?? FallbackSynopsisService.defaultModel
        let body = try Self.rulesRequestBody(model: model, boundary: boundary, buckets: config.moodBuckets, manual: manual, films: answered)
        let response = try await anthropic.messages(apiKey: apiKey, model: model, body: body, timeout: .seconds(120), context: context)
        return try Self.parseRules(response.text)
    }

    static func rulesRequestBody(model: String, boundary: Boundary, buckets: [String: MoodBucket], manual: String, films: [Film]) throws -> Data {
        func describe(_ slug: String) -> String {
            guard let b = buckets[slug] else { return slug }
            var lines = ["\(slug): \(b.title)", b.description]
            if let q = b.qualifies { lines.append("Qualifies when: " + q.joined(separator: " ")) }
            if let m = b.anchorsMiss { lines.append("Does not fit: " + m.joined(separator: "; ")) }
            return lines.joined(separator: "\n")
        }
        var user: [String] = []
        user.append("## The boundary\n\(describe(boundary.left))\n\n\(describe(boundary.right))")
        user.append("## The owner's manual guide (context; where the owner's answers contradict a mood's description, the rule wins)\n\(manual)")
        var lines: [String] = []
        for film in films {
            let answer = film.answer == "neither" ? "neither" : (film.answer == boundary.left ? "left (\(boundary.left))" : "right (\(boundary.right))")
            let p = "left \(film.leftProbability.map { String(format: "%.2f", $0) } ?? "-"), right \(film.rightProbability.map { String(format: "%.2f", $0) } ?? "-")"
            lines.append("- \(film.title): owner says \(answer). Residue: \(film.residue ?? "(none)"). Model probabilities: \(p).")
        }
        user.append("## The owner's answers\n" + lines.joined(separator: "\n"))
        user.append("## Task\nWrite at most \(maxRules) rules, one sentence each, that would let a careful reader make the owner's calls on this boundary for films they have not seen. A rule names a concrete, checkable feature of a film (its ending, its register, its country, what reviews say), never a title, and names the mood it is about by its slug (for example regional-gems), because each rule is read inside that mood's own question. Do not restate the mood descriptions; a rule may override them. Return JSON: {\"rules\": [\"...\"]}.")
        let system = "You write filing rules for a film mood taxonomy from an owner's own decisions. You are precise, concrete and brief."
        let bodyObject: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": system,
            "messages": [["role": "user", "content": user.joined(separator: "\n\n")]],
            "output_config": [
                "format": ["type": "json_schema", "schema": [
                    "type": "object", "additionalProperties": false, "required": ["rules"],
                    "properties": ["rules": ["type": "array", "items": ["type": "string"], "maxItems": maxRules]],
                ]],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: bodyObject, options: [.sortedKeys])
    }

    static func parseRules(_ text: String) throws -> [String] {
        struct Raw: Decodable { let rules: [String] }
        let cleaned = text.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8), let raw = try? JSONDecoder().decode(Raw.self, from: data) else {
            throw TeachError.unusableRules(String(cleaned.prefix(200)))
        }
        return raw.rules.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(maxRules).map { $0 }
    }

    /// Appends the accepted rules to the learned guide, bumps its version, and re-grades the films
    /// whose top two moods touch the boundary.
    func acceptRules(boundaryKey: String, rules: [String], now: Date = Date()) async throws -> Accepted {
        guard let boundary = Boundary(key: boundaryKey) else { throw TeachError.badBoundary(boundaryKey) }
        let cleaned = rules.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { throw TeachError.noRules }
        var learned = try await GuideStore.learned(settings: settings)
        for text in cleaned where !learned.contains(where: { $0.text == text }) {
            learned.append(GuideStore.LearnedRule(boundary: boundary.key, text: text, acceptedAt: now))
        }
        let version = try await GuideStore.setLearned(learned, settings: settings)
        let ids = try await filmsTouching(boundary)
        var started = false
        if !ids.isEmpty {
            do {
                _ = try await backfill.startRegrade(ids: ids, trigger: .manual)
                started = true
            } catch {
                logger.warning("teach: regrade not started: \(error)")
            }
        }
        return Accepted(guideVersion: version, rules: cleaned.count, regradeStarted: started, regradeFilms: ids.count)
    }

    func removeRule(at index: Int) async throws -> Int {
        var learned = try await GuideStore.learned(settings: settings)
        guard learned.indices.contains(index) else { throw TeachError.noRules }
        learned.remove(at: index)
        return try await GuideStore.setLearned(learned, settings: settings)
    }

    /// Films whose current decision has either side of the boundary among its top two moods.
    func filmsTouching(_ boundary: Boundary) async throws -> [String] {
        let db = fluent.db()
        let movies = try await Movie.query(on: db).all().filter { $0.currentDecisionId != nil }
        let decisionIds = movies.compactMap(\.currentDecisionId)
        guard !decisionIds.isEmpty else { return [] }
        var decisionById: [UUID: Decision] = [:]
        for d in try await Decision.query(on: db).filter(\.$id ~~ decisionIds).all() {
            if let id = d.id { decisionById[id] = d }
        }
        let known = Set(config.moodBuckets.keys)
        let order1 = config.moodBuckets.keys.sorted() + [JevClient.noneOption]
        var ids: [String] = []
        for movie in movies {
            guard let id = movie.currentDecisionId, let decision = decisionById[id] else { continue }
            var top: [String] = []
            if let json = decision.classifierJson, let response = try? JSONDecoder().decode(JevClient.Response.self, from: Data(json.utf8)) {
                let probs = JevClient.parse(response, buckets: config.moodBuckets, order1: order1, provider: "typesafe", fallbackModel: "", rawJson: "").probabilities
                top = probs.sorted { $0.value > $1.value }.prefix(2).map(\.key)
            } else if let json = decision.readerJson, let answer = try? ReaderService.parse(json, knownSlugs: known, maxTags: config.maxAutoTags, logger: logger) {
                top = answer.candidates.sorted { $0.confidence > $1.confidence }.prefix(2).map(\.slug)
            }
            if top.contains(boundary.left) || top.contains(boundary.right) { ids.append(movie.jellyfinId) }
        }
        return ids
    }
}

enum TeachError: Error, CustomStringConvertible {
    case badBoundary(String)
    case badAnswer(String)
    case notEnoughAnswers(Int, Int)
    case unusableRules(String)
    case noRules

    var description: String {
        switch self {
        case .badBoundary(let key): return "Not a boundary: \(key)"
        case .badAnswer(let answer): return "Not an answer for this boundary: \(answer)"
        case .notEnoughAnswers(let n, let minimum): return "Answer at least \(minimum) films first (\(n) so far)"
        case .unusableRules(let text): return "The model returned unusable rules: \(text)"
        case .noRules: return "No rules to accept"
        }
    }
}
