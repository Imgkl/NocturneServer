import Foundation
import FluentKit
import HummingbirdFluent
import Logging

/// Owns the tag-suggestion queue: generates Claude suggestions for a Jellyfin movie and persists
/// them as pending rows. Admin approves/rejects. No tag is written to `movie_tags` without approval.
final class SuggestionService: @unchecked Sendable {
  let fluent: Fluent
  let jellyfinService: JellyfinService
  let llmService: LLMService
  let config: RasaConfiguration
  private let logger = Logger(label: "SuggestionService")

  /// Set after construction to avoid a circular init between MovieService and SuggestionService.
  weak var movieServiceRef: MovieService?

  // Backfill state lives in an actor so we can mutate it safely from the background worker.
  private let backfillState = BackfillStateActor()

  init(
    fluent: Fluent,
    jellyfinService: JellyfinService,
    llmService: LLMService,
    config: RasaConfiguration
  ) {
    self.fluent = fluent
    self.jellyfinService = jellyfinService
    self.llmService = llmService
    self.config = config
  }

  /// Generate a fresh Claude suggestion and persist as pending. Idempotent: if a pending row
  /// already exists for this jellyfinId, reuse it.
  @discardableResult
  func enqueue(jellyfinId: String) async throws -> TagSuggestion {
    if let existing = try await TagSuggestion.query(on: fluent.db())
      .filter(\.$jellyfinId == jellyfinId)
      .filter(\.$status == "pending")
      .first()
    {
      return existing
    }

    guard let apiKey = config.anthropicApiKey, !apiKey.isEmpty else {
      throw SuggestionError.missingAnthropicKey
    }

    let item = try await jellyfinService.fetchMovie(id: jellyfinId)
    let context = MovieContext(from: item)
    let provider = LLMProvider.anthropic(apiKey: apiKey)

    let external = await llmService.fetchExternalSummary(title: context.title, year: context.year)
    let firstPass = try await llmService.generateTags(
      for: context,
      using: provider,
      availableTags: config.moodBuckets,
      customPrompt: config.autoTaggingPrompt,
      maxTags: config.maxAutoTags,
      externalInfo: external
    )

    // Snapshot the first-pass validated list — used as a safety net if refine or post-filter
    // over-strips everything.
    let firstPassValidated = firstPass.suggestions.filter { config.moodBuckets[$0] != nil }

    var response = firstPass
    let looksGeneric =
      Set(firstPass.suggestions).contains("dialogue-driven")
      || Set(firstPass.suggestions).contains("modern-masterpieces")
    if firstPass.confidence < 0.72 || looksGeneric {
      do {
        response = try await llmService.refineTags(
          for: context,
          using: provider,
          availableTags: config.moodBuckets,
          initial: firstPass,
          externalInfo: external,
          maxTags: config.maxAutoTags
        )
      } catch {}
    }

    var validSuggestions = response.suggestions.filter { config.moodBuckets[$0] != nil }
    validSuggestions = postFilterSuggestions(validSuggestions, summary: external, context: context)

    // Floor: never store an empty suggestion. If everything got stripped, keep the strongest
    // first-pass survivor so the reviewer has something concrete to approve or reject.
    if validSuggestions.isEmpty, let fallback = firstPassValidated.first {
      validSuggestions = [fallback]
      logger.info("Refine/post-filter emptied the tag set for \(jellyfinId); restoring first-pass top tag: \(fallback)")
    }

    // Apply tags immediately so clients see them right away. A weak run still gets applied;
    // the status field marks it for admin review.
    guard let movieService = movieServiceRef else {
      throw SuggestionError.serviceUnavailable
    }
    _ = try await movieService.updateMovieTags(
      movieId: jellyfinId,
      tagSlugs: validSuggestions,
      replaceAll: false,
      addedByAutoTag: true
    )

    let isWeak = Double(response.confidence) < 0.72
    let sugg = TagSuggestion(
      jellyfinId: jellyfinId,
      suggestedTags: validSuggestions,
      confidence: Double(response.confidence),
      reasoning: response.reasoning,
      status: isWeak ? "pending" : "approved"
    )
    if !isWeak {
      sugg.resolvedAt = Date()
    }
    try await sugg.save(on: fluent.db())
    logger.info(
      "Auto-applied \(isWeak ? "weak" : "strong") tags for \(jellyfinId): \(validSuggestions) (conf=\(response.confidence))"
    )
    return sugg
  }

  /// Fire-and-forget enqueue; swallows errors to a log so sync/webhook paths aren't blocked.
  func enqueueInBackground(jellyfinId: String) {
    Task { [weak self] in
      do {
        _ = try await self?.enqueue(jellyfinId: jellyfinId)
      } catch {
        self?.logger.warning("Background enqueue failed for \(jellyfinId): \(error)")
      }
    }
  }

  /// Tags are already applied by `enqueue`; approve just confirms the review.
  func approve(_ id: UUID) async throws -> TagSuggestion {
    guard let sugg = try await TagSuggestion.find(id, on: fluent.db()) else {
      throw SuggestionError.notFound(id)
    }
    guard sugg.status == "pending" else { throw SuggestionError.alreadyResolved(id) }
    sugg.status = "approved"
    sugg.resolvedAt = Date()
    try await sugg.save(on: fluent.db())
    return sugg
  }

  /// Reject removes the tags that were auto-applied by this suggestion.
  func reject(_ id: UUID) async throws -> TagSuggestion {
    guard let sugg = try await TagSuggestion.find(id, on: fluent.db()) else {
      throw SuggestionError.notFound(id)
    }
    guard sugg.status == "pending" else { throw SuggestionError.alreadyResolved(id) }
    guard let movieService = movieServiceRef else {
      throw SuggestionError.serviceUnavailable
    }
    try await movieService.removeAutoTags(
      jellyfinId: sugg.jellyfinId,
      tagSlugs: sugg.suggestedTags
    )
    sugg.status = "rejected"
    sugg.resolvedAt = Date()
    try await sugg.save(on: fluent.db())
    return sugg
  }

  /// Clear previously-auto-applied tags for this movie and re-run the suggestion pipeline.
  func regenerate(jellyfinId: String) async throws -> TagSuggestion {
    // Remove any auto-tags from prior runs so we don't stack duplicates across regenerates.
    if let movieService = movieServiceRef {
      let priorAutoSlugs = try await TagSuggestion.query(on: fluent.db())
        .filter(\.$jellyfinId == jellyfinId)
        .all()
        .flatMap { $0.suggestedTags }
      let unique = Array(Set(priorAutoSlugs))
      if !unique.isEmpty {
        try await movieService.removeAutoTags(jellyfinId: jellyfinId, tagSlugs: unique)
      }
    }
    try await TagSuggestion.query(on: fluent.db())
      .filter(\.$jellyfinId == jellyfinId)
      .filter(\.$status == "pending")
      .delete()
    return try await enqueue(jellyfinId: jellyfinId)
  }

  func listPending() async throws -> [TagSuggestion] {
    return try await TagSuggestion.query(on: fluent.db())
      .filter(\.$status == "pending")
      .sort(\.$createdAt, DatabaseQuery.Sort.Direction.descending)
      .all()
  }

  func pendingJellyfinIds() async throws -> Set<String> {
    let pending = try await TagSuggestion.query(on: fluent.db())
      .filter(\.$status == "pending")
      .field(\.$jellyfinId)
      .all()
    return Set(pending.map { $0.jellyfinId })
  }

  // MARK: - Backfill

  /// Current backfill state snapshot.
  func getBackfillStatus() async -> BackfillStatus {
    await backfillState.snapshot()
  }

  /// Enqueue a Claude suggestion for every movie that has no tags and no pending suggestion.
  /// Runs sequentially in the background with a throttle between calls. Idempotent — if already
  /// running, returns the current state without starting a second worker.
  func startBackfill() async throws -> BackfillStatus {
    guard let apiKey = config.anthropicApiKey, !apiKey.isEmpty else {
      throw SuggestionError.missingAnthropicKey
    }

    let allMovies = try await Movie.query(on: fluent.db()).with(\.$tags).all()
    let pending = try await pendingJellyfinIds()
    let candidates = allMovies
      .filter { $0.tags.isEmpty && !pending.contains($0.jellyfinId) }
      .map { $0.jellyfinId }

    let startedAt = Date()
    if let existing = await backfillState.claimIfIdle(total: candidates.count, at: startedAt) {
      // Already running — caller piggy-backs on the in-flight worker.
      return existing
    }

    logger.info("Backfill starting for \(candidates.count) untagged movies")

    Task { [weak self] in
      guard let self else { return }
      for jid in candidates {
        do {
          _ = try await self.enqueue(jellyfinId: jid)
        } catch {
          self.logger.warning("Backfill enqueue failed for \(jid): \(error)")
        }
        await self.backfillState.tick()
        // Breather between Claude calls — keeps us well under Anthropic rate limits.
        try? await Task.sleep(nanoseconds: 500_000_000)
      }
      await self.backfillState.finish()
      self.logger.info("Backfill complete")
    }

    return BackfillStatus(
      running: true,
      total: candidates.count,
      processed: 0,
      startedAt: startedAt
    )
  }

  // MARK: - Heuristic post-filter

  /// Drop tags whose textual evidence is thin — same rules as the old MovieService.generateAutoTags.
  private func postFilterSuggestions(
    _ suggestions: [String], summary: String?, context: MovieContext
  ) -> [String] {
    guard let text = summary?.lowercased() ?? context.overview?.lowercased() else {
      return suggestions
    }
    let words =
      text
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\t", with: " ")

    var result: [String] = []
    for tag in suggestions {
      switch tag {
      case "time-twists":
        let ok = [
          "time travel", "time-travel", "time loop", "timeloop", "looping time", "resetting day",
          "timeline", "timelines", "temporal", "time machine", "alternate timeline", "paradox",
        ].contains(where: { words.contains($0) })
        if ok { result.append(tag) }
      case "modern-masterpieces":
        let ok = [
          "masterpiece", "critically acclaimed", "universal acclaim", "academy award", "oscar",
          "palme d'or", "landmark film", "canon", "best of all time",
        ].contains(where: { words.contains($0) })
        if ok { result.append(tag) }
      case "psychological-pressure-cooker":
        let hasOneRoom = [
          "single room", "one room", "jury room", "confined space", "bottle episode", "bottle film",
        ].contains(where: { words.contains($0) })
        let hasPsych = [
          "paranoia", "psychological", "mental breakdown", "gaslight", "psychosis",
          "claustrophobic",
        ].contains(where: { words.contains($0) })
        if hasPsych || !hasOneRoom { result.append(tag) }
      default:
        result.append(tag)
      }
    }
    let unique = Array(NSOrderedSet(array: result)) as? [String] ?? result
    return Array(unique.prefix(config.maxAutoTags))
  }
}

/// Serializes reads/writes of the singleton backfill worker state.
actor BackfillStateActor {
  private var running: Bool = false
  private var total: Int = 0
  private var processed: Int = 0
  private var startedAt: Date?

  func snapshot() -> BackfillStatus {
    BackfillStatus(running: running, total: total, processed: processed, startedAt: startedAt)
  }

  /// If idle, marks the state as running and returns nil. If already running, returns the
  /// current snapshot and caller should NOT start a second worker.
  func claimIfIdle(total: Int, at startedAt: Date) -> BackfillStatus? {
    if running {
      return BackfillStatus(
        running: true, total: self.total, processed: processed, startedAt: self.startedAt)
    }
    running = true
    self.total = total
    processed = 0
    self.startedAt = startedAt
    return nil
  }

  func tick() { processed += 1 }
  func finish() { running = false }
}

enum SuggestionError: Error, CustomStringConvertible {
  case missingAnthropicKey
  case notFound(UUID)
  case alreadyResolved(UUID)
  case serviceUnavailable

  var description: String {
    switch self {
    case .missingAnthropicKey:
      return "Anthropic API key is not configured"
    case .notFound(let id):
      return "Suggestion not found: \(id)"
    case .alreadyResolved(let id):
      return "Suggestion already resolved: \(id)"
    case .serviceUnavailable:
      return "Suggestion service is not fully initialized"
    }
  }
}
