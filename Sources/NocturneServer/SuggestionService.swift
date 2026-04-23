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
  let config: NocturneConfiguration
  private let logger = Logger(label: "SuggestionService")

  /// Set after construction to avoid a circular init between MovieService and SuggestionService.
  weak var movieServiceRef: MovieService?

  // Backfill state lives in an actor so we can mutate it safely from the background worker.
  private let backfillState = BackfillStateActor()

  init(
    fluent: Fluent,
    jellyfinService: JellyfinService,
    llmService: LLMService,
    config: NocturneConfiguration
  ) {
    self.fluent = fluent
    self.jellyfinService = jellyfinService
    self.llmService = llmService
    self.config = config
  }

  /// Generate a fresh Claude suggestion and persist as pending. When `replaceExistingPending`
  /// is true, any existing pending row for this movie is superseded so the reviewer sees the
  /// new suggestion instead of two stacked rows. When false (default), a pre-existing pending
  /// row short-circuits the call so we don't burn API budget on duplicates.
  ///
  /// `calibration` can be provided by callers (e.g. the backfill worker) to avoid rebuilding
  /// the per-tag user-decision map on every enqueue. If nil, it's built fresh here.
  @discardableResult
  func enqueue(
    jellyfinId: String,
    replaceExistingPending: Bool = false,
    calibration: [String: TagCalibration]? = nil
  ) async throws -> TagSuggestion {
    let existing = try await TagSuggestion.query(on: fluent.db())
      .filter(\.$jellyfinId == jellyfinId)
      .filter(\.$status == "pending")
      .all()

    if !existing.isEmpty {
      if !replaceExistingPending {
        return existing[0]
      }
      for old in existing {
        old.status = "superseded"
        old.resolvedAt = Date()
        try await old.save(on: fluent.db())
      }
    }

    guard let apiKey = config.anthropicApiKey, !apiKey.isEmpty else {
      throw SuggestionError.missingAnthropicKey
    }

    let cal: [String: TagCalibration]
    if let calibration {
      cal = calibration
    } else {
      cal = (try? await buildCalibration(
        fluent: fluent, jellyfinService: jellyfinService, availableTags: config.moodBuckets
      )) ?? [:]
    }
    return try await runEnqueue(
      jellyfinId: jellyfinId, apiKey: apiKey, calibration: cal)
  }

  /// Shared enqueue worker — pulled out so backfill/reprocess can build calibration ONCE and
  /// reuse it across every candidate (instead of re-querying on every call).
  @discardableResult
  private func runEnqueue(
    jellyfinId: String,
    apiKey: String,
    calibration: [String: TagCalibration]
  ) async throws -> TagSuggestion {
    let item = try await jellyfinService.fetchMovie(id: jellyfinId)
    let context = MovieContext(from: item)
    let provider = LLMProvider.anthropic(apiKey: apiKey)

    let external = await llmService.fetchExternalSummary(title: context.title, year: context.year)
    let firstPass = try await llmService.generateTags(
      for: context,
      using: provider,
      availableTags: config.moodBuckets,
      calibration: calibration,
      customPrompt: config.autoTaggingPrompt,
      maxTags: config.maxAutoTags,
      externalInfo: external
    )

    logger.info(
      "[\(jellyfinId)] firstPass: \(firstPass.tags.count) tags (min conf \(firstPass.confidence)) slugs=\(firstPass.suggestions)")

    // Snapshot the first-pass validated tag/confidence list — used as a safety net if refine
    // or the per-tag floor over-strips everything.
    let firstPassValidated = firstPass.tags.filter { config.moodBuckets[$0.slug] != nil }

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
          calibration: calibration,
          initial: firstPass,
          externalInfo: external,
          maxTags: config.maxAutoTags
        )
        logger.info("[\(jellyfinId)] refine: \(response.tags.count) tags slugs=\(response.suggestions)")
      } catch {
        logger.warning("[\(jellyfinId)] refine failed, keeping firstPass — \(error)")
      }
    }

    // Per-tag floor: drop any tag whose confidence fails its bucket's minConfidence.
    var survivingTags: [(String, Double)] = []
    for tag in response.tags {
      guard let bucket = config.moodBuckets[tag.slug] else { continue }
      let floor = bucket.minConfidence ?? 0.72
      if tag.confidence >= floor {
        survivingTags.append((tag.slug, tag.confidence))
      } else {
        logger.info(
          "[\(jellyfinId)] dropped \(tag.slug): conf=\(tag.confidence) < floor=\(floor)")
      }
    }
    logger.info(
      "[\(jellyfinId)] after per-tag floor: \(survivingTags.count) of \(response.tags.count) survived")
    var validSuggestions = survivingTags.map(\.0)
    validSuggestions = postFilterSuggestions(validSuggestions, summary: external, context: context)

    // Floor: never store an empty suggestion. Keep the strongest first-pass survivor so the
    // reviewer has something concrete to approve or reject, even if it failed its own floor.
    if validSuggestions.isEmpty {
      if let fallback = firstPassValidated.max(by: { $0.confidence < $1.confidence }) {
        validSuggestions = [fallback.slug]
        survivingTags = [(fallback.slug, fallback.confidence)]
        logger.warning(
          "[\(jellyfinId)] ALL TAGS STRIPPED — fallback to first-pass top: \(fallback.slug) (conf=\(fallback.confidence))"
        )
      } else {
        // Absolute fallback: the LLM returned nothing parseable. Write a zero-tag pending row
        // so the reviewer knows this movie failed to auto-tag — the edit-tags flow (v0.0.76+)
        // lets them manually add tags and approve from the pending list.
        logger.warning(
          "[\(jellyfinId)] LLM returned no parseable tags — writing empty pending row for manual review"
        )
        let sugg = TagSuggestion(
          jellyfinId: jellyfinId,
          suggestedTags: [],
          confidence: 0.0,
          reasoning: "auto-tagger returned no valid tags — review manually",
          status: "pending"
        )
        try await sugg.save(on: fluent.db())
        return sugg
      }
    }

    // Apply tags immediately so clients see them right away. A weak run still gets applied;
    // the status field marks it for admin review.
    guard let movieService = movieServiceRef else {
      throw SuggestionError.serviceUnavailable
    }
    _ = try await movieService.updateMovieTags(
      jellyfinId: jellyfinId,
      tagSlugs: validSuggestions,
      replaceAll: false,
      addedByAutoTag: true
    )

    // Row-level confidence = min across surviving tags. Pending if any surviving tag < 0.72.
    let rowConfidence = survivingTags.map(\.1).min() ?? 0
    let isWeak = rowConfidence < 0.72
    let sugg = TagSuggestion(
      jellyfinId: jellyfinId,
      suggestedTags: validSuggestions,
      confidence: rowConfidence,
      reasoning: response.residue ?? response.reasoning,
      status: isWeak ? "pending" : "approved"
    )
    if !isWeak {
      sugg.resolvedAt = Date()
    }
    try await sugg.save(on: fluent.db())
    logger.info(
      "Auto-applied \(isWeak ? "weak" : "strong") tags for \(jellyfinId): \(validSuggestions) (minConf=\(rowConfidence))"
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

  /// Approve — semantics depend on `kind`:
  /// - additive: tags are already applied by `enqueue`; approval just confirms the review. When
  ///   `overrideTags` is supplied, the reviewer's edited set replaces the originals on the movie
  ///   and the row is rewritten to match.
  /// - removal: actually drop `removalTagSlug` now (the worker left it on because confidence was
  ///   below the tag's floor). `overrideTags` is ignored for removal rows.
  func approve(_ id: UUID, overrideTags: [String]? = nil) async throws -> TagSuggestion {
    guard let sugg = try await TagSuggestion.find(id, on: fluent.db()) else {
      throw SuggestionError.notFound(id)
    }
    guard sugg.status == "pending" else { throw SuggestionError.alreadyResolved(id) }
    guard let movieService = movieServiceRef else {
      throw SuggestionError.serviceUnavailable
    }

    if sugg.kind == "removal" {
      if let slug = sugg.removalTagSlug, !slug.isEmpty {
        try await movieService.removeAutoTags(
          jellyfinId: sugg.jellyfinId, tagSlugs: [slug])
      }
      sugg.status = "approved"
      sugg.resolvedAt = Date()
      try await sugg.save(on: fluent.db())
      return sugg
    }

    if let overrideTags {
      let validOverrides = overrideTags.filter { config.moodBuckets[$0] != nil }
      _ = try await movieService.updateMovieTags(
        jellyfinId: sugg.jellyfinId,
        tagSlugs: validOverrides,
        replaceAll: true,
        addedByAutoTag: false
      )
      sugg.suggestedTags = validOverrides
    }

    sugg.status = "approved"
    sugg.resolvedAt = Date()
    try await sugg.save(on: fluent.db())
    return sugg
  }

  /// Reject — semantics depend on `kind`:
  /// - additive: removes the tags that were auto-applied by this suggestion.
  /// - removal: leaves the tag in place (user disagrees with the drop). No tag writes.
  func reject(_ id: UUID) async throws -> TagSuggestion {
    guard let sugg = try await TagSuggestion.find(id, on: fluent.db()) else {
      throw SuggestionError.notFound(id)
    }
    guard sugg.status == "pending" else { throw SuggestionError.alreadyResolved(id) }
    guard let movieService = movieServiceRef else {
      throw SuggestionError.serviceUnavailable
    }
    if sugg.kind != "removal" {
      try await movieService.removeAutoTags(
        jellyfinId: sugg.jellyfinId,
        tagSlugs: sugg.suggestedTags
      )
    }
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

  /// Request cancellation of the in-flight backfill/reprocess worker. The worker checks this
  /// flag before each iteration and bails cleanly — one Claude call may still finish
  /// (already in-flight), but no new calls fire after cancel arrives.
  func cancelBackfill() async {
    await backfillState.requestCancel()
    logger.info("Backfill cancel requested")
  }

  /// Enqueue a Claude suggestion for every movie that needs one — i.e. no tags at all, or
  /// currently in pending-review state so the reviewer can see a fresh take. Runs sequentially
  /// in the background with a throttle between calls. Idempotent — if already running, returns
  /// the current state without starting a second worker.
  func startBackfill() async throws -> BackfillStatus {
    guard let apiKey = config.anthropicApiKey, !apiKey.isEmpty else {
      throw SuggestionError.missingAnthropicKey
    }

    let allMovies = try await Movie.query(on: fluent.db()).with(\.$tags).all()
    let pending = try await pendingJellyfinIds()
    let candidates = allMovies
      .filter { $0.tags.isEmpty || pending.contains($0.jellyfinId) }
      .map { $0.jellyfinId }

    return try await runWorker(
      label: "Backfill", jellyfinIds: candidates, replaceExistingPending: true)
  }

  /// Clear tags on every movie, supersede every pending suggestion, then re-run the auto-tagger
  /// against the entire library. Used after taxonomy changes to get a clean slate.
  func startReprocessAll() async throws -> BackfillStatus {
    guard let apiKey = config.anthropicApiKey, !apiKey.isEmpty else {
      throw SuggestionError.missingAnthropicKey
    }

    let allMovies = try await Movie.query(on: fluent.db()).with(\.$tags).all()

    // Detach every tag link so the run starts from a clean slate.
    for movie in allMovies where !movie.tags.isEmpty {
      try await movie.$tags.detach(movie.tags, on: fluent.db())
    }

    // Supersede every pending suggestion — they refer to the pre-reprocess tag set.
    let oldPending = try await TagSuggestion.query(on: fluent.db())
      .filter(\.$status == "pending")
      .all()
    let now = Date()
    for old in oldPending {
      old.status = "superseded"
      old.resolvedAt = now
      try await old.save(on: fluent.db())
    }

    let candidates = allMovies.map { $0.jellyfinId }
    return try await runWorker(
      label: "Reprocess-all", jellyfinIds: candidates, replaceExistingPending: true)
  }

  /// Shared throttled worker loop. Claims the backfill state actor, schedules a background task
  /// that walks the candidate list with a breather between Claude calls. Builds user-calibration
  /// ONCE up front so the expensive Jellyfin + DB join doesn't run per movie.
  private func runWorker(
    label: String, jellyfinIds: [String], replaceExistingPending: Bool
  ) async throws -> BackfillStatus {
    // A refinement holds the same actor mutex — reject backfill starts so the user gets a clear
    // error instead of a misleading "idle" snapshot.
    if await backfillState.currentMode() == .refine {
      throw SuggestionError.refinementInProgress
    }

    let startedAt = Date()
    let claimed = await backfillState.claimIfIdle(
      total: jellyfinIds.count, at: startedAt, mode: .backfill)
    if !claimed {
      return await backfillState.snapshot()
    }

    let calibration = (try? await buildCalibration(
      fluent: fluent, jellyfinService: jellyfinService, availableTags: config.moodBuckets
    )) ?? [:]

    logger.info("\(label) starting for \(jellyfinIds.count) movies")

    Task { [weak self] in
      guard let self else { return }
      for jid in jellyfinIds {
        if await self.backfillState.isCancelled() {
          self.logger.info("\(label) cancelled mid-run")
          break
        }
        do {
          _ = try await self.enqueue(
            jellyfinId: jid,
            replaceExistingPending: replaceExistingPending,
            calibration: calibration
          )
        } catch {
          self.logger.warning("\(label) enqueue failed for \(jid): \(error)")
        }
        await self.backfillState.tick()
        // Breather between Claude calls. 1.5s keeps us under ~40 RPM which matches
        // Anthropic Tier 1 ceilings; actual 429s also retry with backoff in LLMService.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
      }
      await self.backfillState.finish()
      self.logger.info("\(label) complete")
    }

    return BackfillStatus(
      running: true,
      total: jellyfinIds.count,
      processed: 0,
      startedAt: startedAt,
      cancelled: nil
    )
  }

  // MARK: - Per-tag refinement

  /// Current refinement snapshot — used both for polling and by the start endpoint when the
  /// actor is already busy with a refinement.
  func getTagRefinementStatus() async -> TagRefinementStatus {
    await backfillState.refinementSnapshot()
  }

  /// Shares the cancel flag with backfill — same worker, same actor, same cancellation path.
  func cancelTagRefinement() async {
    await backfillState.requestCancel()
    logger.info("Tag refinement cancel requested")
  }

  /// Walk every movie that has `tagSlug` applied *by the auto-tagger* and ask Claude whether the
  /// tag still describes the residue. Skips manually-added pivots — user decisions aren't
  /// second-guessed. High-confidence mismatches are removed immediately; lower-confidence
  /// verdicts land as kind="removal" pending rows. Alternate tags Claude proposes ride the
  /// existing additive flow (auto-applied + pending review).
  func startTagRefinement(tagSlug: String) async throws -> TagRefinementStatus {
    guard let bucket = config.moodBuckets[tagSlug] else {
      throw SuggestionError.tagNotFound(tagSlug)
    }
    guard let apiKey = config.anthropicApiKey, !apiKey.isEmpty else {
      throw SuggestionError.missingAnthropicKey
    }
    if await backfillState.currentMode() == .backfill {
      throw SuggestionError.backfillInProgress
    }

    // Candidate movies = pivots for this tag where the tag was auto-applied.
    guard let tagRow = try await Tag.query(on: fluent.db())
      .filter(\.$slug == tagSlug)
      .first()
    else {
      // Nothing to do — surface a completed-looking snapshot.
      return TagRefinementStatus(
        running: false, tagSlug: tagSlug, total: 0, processed: 0, removed: 0,
        addSuggestions: 0, removeSuggestions: 0, startedAt: nil, cancelled: nil)
    }
    let pivots = try await MovieTag.query(on: fluent.db())
      .filter(\.$tag.$id == tagRow.requireID())
      .filter(\.$addedByAutoTag == true)
      .all()
    let movieIds = pivots.map { $0.$movie.id }
    let movies: [Movie]
    if movieIds.isEmpty {
      movies = []
    } else {
      movies = try await Movie.query(on: fluent.db()).filter(\.$id ~~ movieIds).all()
    }
    let jellyfinIds = movies.map { $0.jellyfinId }

    let startedAt = Date()
    let claimed = await backfillState.claimIfIdle(
      total: jellyfinIds.count, at: startedAt, mode: .refine, tagSlug: tagSlug)
    if !claimed {
      return await backfillState.refinementSnapshot()
    }

    let calibration = (try? await buildCalibration(
      fluent: fluent, jellyfinService: jellyfinService, availableTags: config.moodBuckets
    )) ?? [:]

    logger.info("Tag refinement starting for \(tagSlug) across \(jellyfinIds.count) movies")

    Task { [weak self] in
      guard let self else { return }
      for jid in jellyfinIds {
        if await self.backfillState.isCancelled() {
          self.logger.info("Tag refinement cancelled mid-run")
          break
        }
        do {
          try await self.processTagRefinement(
            jellyfinId: jid, tagSlug: tagSlug, tag: bucket,
            apiKey: apiKey, calibration: calibration)
        } catch {
          self.logger.warning("Tag refinement failed for \(jid): \(error)")
        }
        await self.backfillState.tick()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
      }
      await self.backfillState.finish()
      self.logger.info("Tag refinement complete for \(tagSlug)")
    }

    return await backfillState.refinementSnapshot()
  }

  private func processTagRefinement(
    jellyfinId: String,
    tagSlug: String,
    tag: MoodBucket,
    apiKey: String,
    calibration: [String: TagCalibration]
  ) async throws {
    guard let movieService = movieServiceRef else {
      throw SuggestionError.serviceUnavailable
    }

    let item = try await jellyfinService.fetchMovie(id: jellyfinId)
    let context = MovieContext(from: item)
    let external = await llmService.fetchExternalSummary(
      title: context.title, year: context.year)
    let provider = LLMProvider.anthropic(apiKey: apiKey)

    let verdict = try await llmService.refineTagForMovie(
      tagSlug: tagSlug,
      tag: tag,
      movie: context,
      using: provider,
      availableTags: config.moodBuckets,
      calibration: calibration,
      externalInfo: external
    )

    let floor = tag.minConfidence ?? 0.72

    if !verdict.keep {
      let reasoning: String? =
        (verdict.evidence?.isEmpty == false ? verdict.evidence : verdict.residue)
      if verdict.confidence >= floor {
        try await movieService.removeAutoTags(
          jellyfinId: jellyfinId, tagSlugs: [tagSlug])
        await backfillState.recordRemoval()
        logger.info(
          "[\(jellyfinId)] auto-removed \(tagSlug) conf=\(verdict.confidence) ≥ floor=\(floor)")
      } else {
        let row = TagSuggestion(
          jellyfinId: jellyfinId,
          suggestedTags: [],
          confidence: verdict.confidence,
          reasoning: reasoning,
          status: "pending",
          kind: "removal",
          removalTagSlug: tagSlug
        )
        try await row.save(on: fluent.db())
        await backfillState.recordRemoveSuggestion()
        logger.info(
          "[\(jellyfinId)] queued removal review for \(tagSlug) conf=\(verdict.confidence) < floor=\(floor)")
      }
    }

    // Alternate tag suggestions — apply + queue for additive review. Mirrors the existing
    // auto-tag flow so the reviewer sees one consistent list.
    guard !verdict.suggestedTags.isEmpty else { return }

    let currentSlugs: Set<String>
    if let movie = try await Movie.query(on: fluent.db())
      .filter(\.$jellyfinId == jellyfinId)
      .with(\.$tags)
      .first()
    {
      currentSlugs = Set(movie.tags.map { $0.slug })
    } else {
      currentSlugs = []
    }

    for alt in verdict.suggestedTags {
      guard alt.slug != tagSlug else { continue }
      guard let altBucket = config.moodBuckets[alt.slug] else { continue }
      let altFloor = altBucket.minConfidence ?? 0.72
      if alt.confidence < altFloor {
        logger.info(
          "[\(jellyfinId)] dropped alt \(alt.slug): conf=\(alt.confidence) < floor=\(altFloor)")
        continue
      }
      if currentSlugs.contains(alt.slug) { continue }

      _ = try await movieService.updateMovieTags(
        jellyfinId: jellyfinId,
        tagSlugs: [alt.slug],
        replaceAll: false,
        addedByAutoTag: true
      )
      let row = TagSuggestion(
        jellyfinId: jellyfinId,
        suggestedTags: [alt.slug],
        confidence: alt.confidence,
        reasoning: alt.evidence,
        status: "pending",
        kind: "additive"
      )
      try await row.save(on: fluent.db())
      await backfillState.recordAddSuggestion()
      logger.info(
        "[\(jellyfinId)] queued additive suggestion \(alt.slug) conf=\(alt.confidence)")
    }
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

enum WorkerMode: Sendable { case backfill, refine }

/// Serializes reads/writes of the singleton long-running worker state. One mode runs at a time
/// (backfill vs per-tag refinement) so the two flows share the cancellation + progress plumbing
/// without stepping on each other's Anthropic quota.
actor BackfillStateActor {
  private var mode: WorkerMode? = nil
  private var cancelRequested: Bool = false
  private var total: Int = 0
  private var processed: Int = 0
  private var startedAt: Date?
  // Refine-only fields
  private var tagSlug: String?
  private var removed: Int = 0
  private var addSuggestions: Int = 0
  private var removeSuggestions: Int = 0

  func currentMode() -> WorkerMode? { mode }

  /// Backfill-facing snapshot. Returns running=false when the actor is idle OR a refinement is
  /// in flight — keeps the existing /backfill/status endpoint honest from the backfill POV.
  func snapshot() -> BackfillStatus {
    guard mode == .backfill else {
      return BackfillStatus(running: false, total: 0, processed: 0, startedAt: nil, cancelled: nil)
    }
    return BackfillStatus(
      running: true, total: total, processed: processed,
      startedAt: startedAt, cancelled: cancelRequested ? true : nil)
  }

  /// Refinement-facing snapshot. Returns running=false when idle OR a backfill is in flight.
  func refinementSnapshot() -> TagRefinementStatus {
    guard mode == .refine else {
      return TagRefinementStatus(
        running: false, tagSlug: nil, total: 0, processed: 0, removed: 0,
        addSuggestions: 0, removeSuggestions: 0, startedAt: nil, cancelled: nil)
    }
    return TagRefinementStatus(
      running: true, tagSlug: tagSlug, total: total, processed: processed,
      removed: removed, addSuggestions: addSuggestions, removeSuggestions: removeSuggestions,
      startedAt: startedAt, cancelled: cancelRequested ? true : nil)
  }

  /// Claim the actor for a new run. Returns true on success; false means the actor is already
  /// occupied (caller should surface the current snapshot or throw based on mode). Resets all
  /// counters on success so a follow-up run starts fresh.
  func claimIfIdle(total: Int, at startedAt: Date, mode: WorkerMode, tagSlug: String? = nil) -> Bool {
    if self.mode != nil { return false }
    self.mode = mode
    cancelRequested = false
    self.total = total
    self.processed = 0
    self.startedAt = startedAt
    self.tagSlug = tagSlug
    self.removed = 0
    self.addSuggestions = 0
    self.removeSuggestions = 0
    return true
  }

  func tick() { processed += 1 }
  func recordRemoval() { removed += 1 }
  func recordAddSuggestion() { addSuggestions += 1 }
  func recordRemoveSuggestion() { removeSuggestions += 1 }

  func finish() {
    mode = nil
    cancelRequested = false
  }

  func requestCancel() { if mode != nil { cancelRequested = true } }
  func isCancelled() -> Bool { cancelRequested }
}

enum SuggestionError: Error, CustomStringConvertible {
  case missingAnthropicKey
  case notFound(UUID)
  case alreadyResolved(UUID)
  case serviceUnavailable
  case tagNotFound(String)
  case backfillInProgress
  case refinementInProgress

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
    case .tagNotFound(let slug):
      return "Tag not found: \(slug)"
    case .backfillInProgress:
      return "A backfill is already running; cancel it before starting a refinement"
    case .refinementInProgress:
      return "A tag refinement is already running; cancel it before starting a backfill"
    }
  }
}
