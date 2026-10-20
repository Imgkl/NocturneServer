import Foundation
import FluentKit
import HummingbirdFluent
import Logging

/// Per-tag feedback distilled from the admin's own decisions. Fed to the reader as
/// "Your recent decisions". Only human-sourced rows count: suggestions a person approved,
/// edited or rejected, and tags a person added by hand. Rows the tagger auto-approved are
/// never calibration, otherwise the model would be fed its own picks as confirmations.
struct TagCalibration: Sendable, Equatable {
    var positives: [String] = []   // film titles where this tag was confirmed
    var negatives: [String] = []   // film titles where this tag was rejected / removed
}

/// Builds `[slug: TagCalibration]` from human labels, with titles supplied by the caller.
///
/// Signal rules:
/// - `tag_suggestions.resolved_by == "user"`, status approved: suggested tags still on the film
///   are positives; suggested tags no longer on the film are negatives (the admin edited them out).
/// - `tag_suggestions.resolved_by == "user"`, status rejected: all suggested tags are negatives.
/// - `movie_tags.label_source == "user"`: positives.
/// - Everything else (auto-approved, pending, superseded, auto tags) is skipped.
///
/// Most recent resolutions first; capped per tag.
func buildCalibration(
    fluent: Fluent,
    titles: [String: String],
    availableTags: [String: MoodBucket],
    maxResolvedRows: Int = 200,
    maxPositives: Int = 5,
    maxNegatives: Int = 3
) async throws -> [String: TagCalibration] {
    let logger = Logger(label: "TagCalibration")
    let db = fluent.db()

    let resolved = try await TagSuggestion.query(on: db)
        .filter(\.$resolvedBy == ResolvedBy.user)
        .group(.or) { group in
            group.filter(\.$status == "approved")
            group.filter(\.$status == "rejected")
        }
        .sort(\.$resolvedAt, .descending)
        .limit(maxResolvedRows)
        .all()

    let jellyfinIds = Set(resolved.map(\.jellyfinId))
    var currentTagsByJellyfinId: [String: Set<String>] = [:]
    if !jellyfinIds.isEmpty {
        let localMovies = try await Movie.query(on: db)
            .with(\.$tags)
            .filter(\.$jellyfinId ~~ Array(jellyfinIds))
            .all()
        for m in localMovies {
            currentTagsByJellyfinId[m.jellyfinId] = Set(m.tags.map(\.slug))
        }
    }

    var result: [String: TagCalibration] = [:]
    func title(_ jellyfinId: String) -> String { titles[jellyfinId] ?? jellyfinId }
    func addPositive(_ slug: String, _ film: String) {
        guard availableTags[slug] != nil else { return }
        var cal = result[slug] ?? TagCalibration()
        if cal.positives.count < maxPositives, !cal.positives.contains(film), !cal.negatives.contains(film) {
            cal.positives.append(film)
            result[slug] = cal
        }
    }
    func addNegative(_ slug: String, _ film: String) {
        guard availableTags[slug] != nil else { return }
        var cal = result[slug] ?? TagCalibration()
        if cal.negatives.count < maxNegatives, !cal.negatives.contains(film), !cal.positives.contains(film) {
            cal.negatives.append(film)
            result[slug] = cal
        }
    }

    for sugg in resolved {
        let film = title(sugg.jellyfinId)
        let suggested = Set(sugg.suggestedTags)
        let current = currentTagsByJellyfinId[sugg.jellyfinId] ?? []
        switch sugg.status {
        case "approved":
            for slug in suggested.intersection(current).sorted() { addPositive(slug, film) }
            for slug in suggested.subtracting(current).sorted() { addNegative(slug, film) }
        case "rejected":
            for slug in suggested.sorted() { addNegative(slug, film) }
        default:
            continue
        }
    }

    // Tags the admin added by hand are confirmations too (most recent first).
    let manual = try await MovieTag.query(on: db)
        .filter(\.$labelSource == LabelSource.user.rawValue)
        .with(\.$movie)
        .with(\.$tag)
        .sort(\.$createdAt, .descending)
        .limit(maxResolvedRows)
        .all()
    for row in manual {
        addPositive(row.tag.slug, title(row.movie.jellyfinId))
    }

    let withSignal = result.filter { !$0.value.positives.isEmpty || !$0.value.negatives.isEmpty }.count
    logger.info("Calibration built from \(resolved.count) human-resolved rows + \(manual.count) manual tags; \(withSignal) tags with signal")
    return result
}

/// Convenience that fetches titles from Jellyfin once. Workers that call `buildCalibration`
/// many times should fetch titles themselves and use the core function.
func buildCalibration(
    fluent: Fluent,
    jellyfinService: JellyfinService,
    availableTags: [String: MoodBucket],
    maxResolvedRows: Int = 200,
    maxPerTag: Int = 5
) async throws -> [String: TagCalibration] {
    var titles: [String: String] = [:]
    do {
        for item in try await jellyfinService.fetchAllMovies() {
            if let id = item.id, let name = item.name { titles[id] = name }
        }
    } catch {
        Logger(label: "TagCalibration").warning("Calibration: Jellyfin title fetch failed, falling back to jellyfinId: \(error)")
    }
    return try await buildCalibration(
        fluent: fluent, titles: titles, availableTags: availableTags,
        maxResolvedRows: maxResolvedRows, maxPositives: maxPerTag, maxNegatives: min(maxPerTag, 3))
}
