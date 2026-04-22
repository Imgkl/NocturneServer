import Foundation
import FluentKit
import HummingbirdFluent
import Logging

/// Per-tag feedback distilled from the user's approve/reject/edit decisions.
/// Fed into the LLM prompt as "Recent user decisions" — makes the tagger
/// sharper with use, without any explicit labeling step.
struct TagCalibration: Sendable {
    var positives: [String] = []   // movie titles where this tag was confirmed
    var negatives: [String] = []   // movie titles where this tag was rejected / removed
}

/// Builds `[slug: TagCalibration]` from resolved `TagSuggestion` rows joined against the
/// current state of `movie_tags`.
///
/// Signal rules:
/// - status="approved" and current movie tags == suggestedTags → all suggested = positive
/// - status="approved" and diff ≠ ∅ (edit happened) → intersection = positive, removed = negative
/// - status="rejected" → all suggested = negative
/// - status="superseded"/"pending" → skipped
///
/// Ordering: most recent resolvedAt first. Cap of `maxPerTag` positives + negatives per tag.
func buildCalibration(
    fluent: Fluent,
    jellyfinService: JellyfinService,
    availableTags: [String: MoodBucket],
    maxResolvedRows: Int = 200,
    maxPerTag: Int = 5
) async throws -> [String: TagCalibration] {
    let logger = Logger(label: "TagCalibration")

    let resolved = try await TagSuggestion.query(on: fluent.db())
        .group(.or) { group in
            group.filter(\.$status == "approved")
            group.filter(\.$status == "rejected")
        }
        .sort(\.$resolvedAt, DatabaseQuery.Sort.Direction.descending)
        .limit(maxResolvedRows)
        .all()

    if resolved.isEmpty { return [:] }

    let jellyfinIds = Set(resolved.map(\.jellyfinId))

    let localMovies = try await Movie.query(on: fluent.db())
        .with(\.$tags)
        .filter(\.$jellyfinId ~~ Array(jellyfinIds))
        .all()
    var currentTagsByJellyfinId: [String: Set<String>] = [:]
    for m in localMovies {
        currentTagsByJellyfinId[m.jellyfinId] = Set(m.tags.map(\.slug))
    }

    var titlesByJellyfinId: [String: String] = [:]
    do {
        let live = try await jellyfinService.fetchAllMovies()
        for item in live {
            if let id = item.id, let name = item.name {
                titlesByJellyfinId[id] = name
            }
        }
    } catch {
        logger.warning("Calibration: Jellyfin title fetch failed, falling back to jellyfinId — \(error)")
    }

    var result: [String: TagCalibration] = [:]

    for sugg in resolved {
        let title = titlesByJellyfinId[sugg.jellyfinId] ?? sugg.jellyfinId
        let suggested = Set(sugg.suggestedTags)
        let current = currentTagsByJellyfinId[sugg.jellyfinId] ?? []

        let positives: Set<String>
        let negatives: Set<String>

        switch sugg.status {
        case "rejected":
            positives = []
            negatives = suggested
        case "approved":
            positives = suggested.intersection(current)
            negatives = suggested.subtracting(current)
        default:
            continue
        }

        for slug in positives where availableTags[slug] != nil {
            var cal = result[slug] ?? TagCalibration()
            if cal.positives.count < maxPerTag, !cal.positives.contains(title) {
                cal.positives.append(title)
                result[slug] = cal
            }
        }
        for slug in negatives where availableTags[slug] != nil {
            var cal = result[slug] ?? TagCalibration()
            if cal.negatives.count < maxPerTag, !cal.negatives.contains(title) {
                cal.negatives.append(title)
                result[slug] = cal
            }
        }
    }

    let withSignal = result.filter { !$0.value.positives.isEmpty || !$0.value.negatives.isEmpty }.count
    logger.info("Calibration built from \(resolved.count) resolved rows — \(withSignal) tags with signal")
    return result
}
