import FluentKit
import Foundation
import HummingbirdFluent
import Logging

/// The spot check: a random sample of tagged films the owner judges mood by mood, a few minutes
/// at a time. Every verdict becomes user labels on the film and a user-resolved row, which is
/// what the eval and Teach read as ground truth.
final class VerifyService: @unchecked Sendable {
    static let kind = "verify"
    static let wrongReason = "marked wrong by the owner"
    /// A mood AI named that was not on the film; shown on the card, so it counts as judged.
    static let consideredReason = "considered by AI, not applied"
    static let addedReason = "added by the owner"

    /// Which films the sample draws from: the owner's watched films (the baseline) or every film.
    enum Scope: String, Sendable {
        case watched
        case all
    }

    /// `tagged`: films carrying a mood from AI, judged mood by mood. `untagged`: films with no mood
    /// at all, where the owner picks from what AI considered or anything else.
    enum Mode: String, Sendable {
        case tagged
        case untagged
    }

    struct Mood: Codable, Sendable, Equatable {
        let slug: String
        let title: String
        /// The grader's probability when one ran for the film, else AI's own confidence.
        let probability: Double?
        let evidence: String?
    }

    struct Film: Codable, Sendable, Equatable {
        let jellyfinId: String
        let title: String
        let year: Int?
        let played: Bool
        let residue: String?
        /// The moods on the film from AI, to judge.
        let moods: [Mood]
        /// Moods AI named that are not on the film, to add with one tap.
        let candidates: [Mood]
    }

    /// Running totals over every verdict so far.
    struct Tally: Codable, Sendable, Equatable {
        let films: Int
        let judged: Int
        let right: Int
        let wrong: Int
    }

    struct Sample: Codable, Sendable {
        let films: [Film]
        /// Films of this scope and mode still unjudged after this sample.
        let remaining: Int
        /// Unjudged films per scope and mode, keyed `watched.tagged`, `all.untagged` and so on.
        let counts: [String: Int]
        let tally: Tally
    }

    struct Saved: Codable, Sendable {
        let kept: [String]
        let wrong: [String]
        let added: [String]
        let tally: Tally
    }

    let fluent: Fluent
    let config: NocturneConfiguration
    let movies: MovieService
    let logger: Logger

    init(fluent: Fluent, config: NocturneConfiguration, movies: MovieService, logger: Logger = Logger(label: "Verify")) {
        self.fluent = fluent
        self.config = config
        self.movies = movies
        self.logger = logger
    }

    /// Films of the scope and mode with no verdict yet, in a seeded order so a reload shows the same
    /// films until they are judged.
    func sample(count: Int, seed: String, scope: Scope = .watched, mode: Mode = .tagged) async throws -> Sample {
        let db = fluent.db()
        let verified = Set(try await TagSuggestion.query(on: db).filter(\.$kind == Self.kind).all().map(\.jellyfinId))
        var autoBy: [String: [String]] = [:]
        var tagged = Set<String>()
        for row in try await MovieTag.query(on: db).with(\.$tag).with(\.$movie).all() {
            tagged.insert(row.movie.jellyfinId)
            if row.labelSource == LabelSource.auto.rawValue { autoBy[row.movie.jellyfinId, default: []].append(row.tag.slug) }
        }
        let allMovies = try await Movie.query(on: db).all()
        func pool(_ scope: Scope, _ mode: Mode) -> [String] {
            allMovies.filter { movie in
                guard !verified.contains(movie.jellyfinId) else { return false }
                guard scope == .all || movie.played else { return false }
                return mode == .tagged ? (autoBy[movie.jellyfinId]?.isEmpty == false) : !tagged.contains(movie.jellyfinId)
            }.map(\.jellyfinId).sorted()
        }
        var counts: [String: Int] = [:]
        for s in [Scope.watched, .all] { for m in [Mode.tagged, .untagged] { counts["\(s.rawValue).\(m.rawValue)"] = pool(s, m).count } }
        let candidates: [String] = pool(scope, mode)
        let picked: [String] = Array(Self.shuffle(candidates, seed: seed).prefix(max(0, count)))
        var films: [Film] = []
        if !picked.isEmpty {
            let movies: [Movie] = try await Movie.query(on: db).filter(\.$jellyfinId ~~ picked).all()
            let decisionIds = movies.compactMap(\.currentDecisionId)
            var decisionById: [UUID: Decision] = [:]
            if !decisionIds.isEmpty {
                for d in try await Decision.query(on: db).filter(\.$id ~~ decisionIds).all() { if let id = d.id { decisionById[id] = d } }
            }
            var identities: [String: EnrichmentService.Identity] = [:]
            for jellyfinId in picked {
                if let row = try await MovieEnrichment.find(jellyfinId, on: db), let json = row.identityJson,
                    let identity = try? JSONDecoder().decode(EnrichmentService.Identity.self, from: Data(json.utf8)) {
                    identities[jellyfinId] = identity
                }
            }
            let known = Set(config.moodBuckets.keys)
            let movieById = Dictionary(uniqueKeysWithValues: movies.map { ($0.jellyfinId, $0) })
            for jellyfinId in picked {
                guard let movie = movieById[jellyfinId] else { continue }
                var evidence: [String: String] = [:]
                var confidence: [String: Double] = [:]
                var probability: [String: Double] = [:]
                var residue: String? = nil
                if let id = movie.currentDecisionId, let decision = decisionById[id] {
                    if let json = decision.readerJson, let answer = try? ReaderService.parse(json, knownSlugs: known, maxTags: config.maxAutoTags, logger: logger) {
                        residue = answer.residue
                        for c in answer.candidates {
                            confidence[c.slug] = c.confidence
                            evidence[c.slug] = c.evidence
                        }
                    }
                    if let classifier = TaggerPipeline.storedClassifier(of: decision, buckets: config.moodBuckets) {
                        probability = classifier.probabilities
                    }
                }
                let applied = autoBy[jellyfinId] ?? []
                let mood: (String) -> Mood = { slug in
                    Mood(slug: slug, title: self.config.moodBuckets[slug]?.title ?? slug, probability: probability[slug] ?? confidence[slug], evidence: evidence[slug])
                }
                let byProbability: (Mood, Mood) -> Bool = { ($0.probability ?? 0, $1.slug) > ($1.probability ?? 0, $0.slug) }
                let moods = applied.map(mood).sorted(by: byProbability)
                let considered = confidence.keys.filter { !applied.contains($0) && known.contains($0) }.map(mood).sorted(by: byProbability)
                let identity = identities[jellyfinId]
                films.append(Film(jellyfinId: jellyfinId, title: identity?.title ?? jellyfinId, year: identity?.year, played: movie.played, residue: residue, moods: moods, candidates: considered))
            }
        }
        return Sample(films: films, remaining: candidates.count - picked.count, counts: counts, tally: try await tally())
    }

    func tally() async throws -> Tally {
        let rows = try await TagSuggestion.query(on: fluent.db()).filter(\.$kind == Self.kind).all()
        var judged = 0
        var wrong = 0
        for row in rows {
            let items = ReviewQueue.items(of: row)
            // Precision counts the moods AI applied and the owner judged, not the ones they added.
            judged += items.filter { $0.kind == .add && $0.applied && $0.reason == nil }.count
            wrong += items.filter { $0.kind == .remove }.count
        }
        return Tally(films: rows.count, judged: judged, right: judged - wrong, wrong: wrong)
    }

    /// The owner's verdict on one film: the wrong moods come off, the rest become the owner's own
    /// tags, `add` lands as the owner's tags, open review rows are superseded, and a user-resolved
    /// verify row records it all. Moods AI considered that the owner did not take are negatives too,
    /// because they were on the card.
    func save(jellyfinId: String, wrong: [String], add: [String] = []) async throws -> Saved {
        let db = fluent.db()
        guard let movie = try await Movie.query(on: db).filter(\.$jellyfinId == jellyfinId).first() else { throw TaggerError.movieNotFound(jellyfinId) }
        let known = Set(config.moodBuckets.keys)
        let applied = try await movies.autoTagSlugs(jellyfinId: jellyfinId)
        let onFilm = Set(try await MovieTag.query(on: db).filter(\.$movie.$id == movie.requireID()).with(\.$tag).all().map(\.tag.slug))
        var considered: [String] = []
        if let id = movie.currentDecisionId, let decision = try await Decision.find(id, on: db), let json = decision.readerJson,
            let answer = try? ReaderService.parse(json, knownSlugs: known, maxTags: config.maxAutoTags, logger: logger) {
            considered = answer.candidates.map(\.slug).filter { !onFilm.contains($0) }
        }
        let added = add.filter { known.contains($0) && !onFilm.contains($0) }
        guard !applied.isEmpty || !added.isEmpty || !considered.isEmpty else { throw VerifyError.nothingToJudge(jellyfinId) }
        let wrongSet = Set(wrong).intersection(applied)
        try await movies.removeAutoTags(jellyfinId: jellyfinId, tagSlugs: wrongSet.sorted())
        try await movies.promoteAutoTagsToUser(jellyfinId: jellyfinId)
        for old in try await TagSuggestion.query(on: db).filter(\.$jellyfinId == jellyfinId).filter(\.$status == "pending").all() {
            old.status = "superseded"
            old.resolvedAt = Date()
            try await old.save(on: db)
        }
        if !added.isEmpty {
            _ = try await movies.updateMovieTags(jellyfinId: jellyfinId, tagSlugs: added, replaceAll: false, labelSource: .user)
        }
        let kept = applied.filter { !wrongSet.contains($0) }
        let items = applied.map { SuggestionItem(slug: $0, probability: 0, evidence: nil, kind: .add, applied: true, reason: nil) }
            + wrongSet.sorted().map { SuggestionItem(slug: $0, probability: 0, evidence: nil, kind: .remove, applied: false, reason: Self.wrongReason) }
            + considered.filter { !added.contains($0) }.map { SuggestionItem(slug: $0, probability: 0, evidence: nil, kind: .add, applied: false, reason: Self.consideredReason) }
            + added.map { SuggestionItem(slug: $0, probability: 0, evidence: nil, kind: .add, applied: true, reason: Self.addedReason) }
        let row = TagSuggestion(jellyfinId: jellyfinId, suggestedTags: applied, confidence: 0, reasoning: nil, status: "approved", kind: Self.kind)
        row.decisionId = movie.currentDecisionId
        row.itemsJson = DecisionRecorder.json(items)
        row.resolvedAt = Date()
        row.resolvedBy = ResolvedBy.user
        try await row.save(on: db)
        logger.info("[\(jellyfinId)] verified: kept \(kept), wrong \(wrongSet.sorted()), added \(added)")
        return Saved(kept: kept, wrong: wrongSet.sorted(), added: added, tally: try await tally())
    }

    /// A seeded Fisher-Yates shuffle, so the same seed gives the same sample.
    static func shuffle(_ ids: [String], seed: String) -> [String] {
        var generator = SeededGenerator(seed: "verify:" + seed)
        var a = ids
        if a.count > 1 {
            for i in stride(from: a.count - 1, to: 0, by: -1) {
                let j = Int(generator.next() % UInt64(i + 1))
                a.swapAt(i, j)
            }
        }
        return a
    }

    /// Today's date, so a reload shows the same sample until it is judged.
    static func daySeed(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }
}

enum VerifyError: Error, CustomStringConvertible {
    case nothingToJudge(String)

    var description: String {
        switch self {
        case .nothingToJudge(let id): return "film \(id) has no tag from the tagger to judge"
        }
    }
}
