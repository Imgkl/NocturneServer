import AsyncHTTPClient
import FluentKit
import Foundation
import HummingbirdFluent
import Logging

final class MovieService {
  let config: RasaConfiguration
  let fluent: Fluent
  var jellyfinService: JellyfinService
  let llmService: LLMService
  private let logger = Logger(label: "MovieService")

  /// Wired post-construction by RasaServerApp to break the cycle with SuggestionService.
  weak var suggestionService: SuggestionService?

  // Sync status tracking
  private var isSyncing = false
  private var lastSyncAt: Date?
  private var lastSyncDuration: TimeInterval?
  private var lastSyncStats = SyncStats()

  init(
    config: RasaConfiguration,
    fluent: Fluent,
    jellyfinService: JellyfinService,
    llmService: LLMService
  ) {
    self.config = config
    self.fluent = fluent
    self.jellyfinService = jellyfinService
    self.llmService = llmService
  }

  /// Insert or touch a Movie row for the given Jellyfin ID; bumps last_seen_at.
  @discardableResult
  func upsertJellyfinId(_ jellyfinId: String) async throws -> Movie {
    if let existing = try await Movie.query(on: fluent.db())
      .filter(\.$jellyfinId == jellyfinId)
      .first()
    {
      existing.lastSeenAt = Date()
      try await existing.save(on: fluent.db())
      return existing
    }
    let movie = Movie(jellyfinId: jellyfinId, lastSeenAt: Date())
    try await movie.save(on: fluent.db())
    return movie
  }

  /// Delete a movie (and its tag relations) by Jellyfin item id. Returns true if deleted.
  func deleteMovieByJellyfinId(_ jellyfinId: String) async throws -> Bool {
    if let movie = try await Movie.query(on: fluent.db())
      .filter(\.$jellyfinId == jellyfinId)
      .with(\.$tags)
      .first()
    {
      let tagSlugs = movie.tags.map { $0.slug }
      try await MovieTag.query(on: fluent.db())
        .filter(\.$movie.$id == movie.requireID())
        .delete()
      try await movie.delete(on: fluent.db())
      try await updateTagUsageCounts(for: tagSlugs)
      logger.info("Deleted movie with Jellyfin id \(jellyfinId)")
      return true
    }
    return false
  }

  // MARK: - Reconfigure Jellyfin at runtime
  func reconfigureJellyfin(baseURL: String, apiKey: String, userId: String) {
    let httpClient = self.jellyfinService.httpClient
    self.jellyfinService = JellyfinService(
      baseURL: baseURL, apiKey: apiKey, userId: userId, httpClient: httpClient)
    logger.info("Jellyfin service reconfigured at runtime")
  }

  private func attemptAutoLoginAndUpdate() async throws -> Bool {
    let store = SettingsStore(db: fluent.db(), logger: logger)
    try await store.ensureTable()
    guard let url = try await store.get("jellyfin_url"),
      let username = try await store.get("jellyfin_username"),
      let encPwd = try await store.get("jellyfin_password_enc")
    else {
      return false
    }
    let key = try SecretsManager.loadOrCreateKey(logger: logger)
    let password = try SecretsManager.decryptString(encPwd, key: key)
    let httpClient = self.jellyfinService.httpClient
    do {
      let auth = try await JellyfinService.login(
        baseURL: url, username: username, password: password, httpClient: httpClient)
      try await store.set("jellyfin_api_key", auth.token)
      try await store.set("jellyfin_user_id", auth.userId)
      reconfigureJellyfin(baseURL: url, apiKey: auth.token, userId: auth.userId)
      return true
    } catch {
      logger.error("Auto-login failed: \(error)")
      return false
    }
  }

  // MARK: - Tag Management

  func updateMovieTags(
    movieId: String,
    tagSlugs: [String],
    replaceAll: Bool,
    addedByAutoTag: Bool = false
  ) async throws -> ClientTagEntry {
    let movie = try await getMovieEntity(id: movieId)
    let validSlugs = try validateTagSlugs(tagSlugs)

    if replaceAll {
      try await MovieTag.query(on: fluent.db())
        .filter(\.$movie.$id == movie.requireID())
        .delete()
    }

    var tags: [Tag] = []
    for slug in validSlugs {
      let tag = try await getOrCreateTag(slug: slug)
      tags.append(tag)
    }

    if replaceAll {
      for tag in tags {
        let movieTag = MovieTag(
          movieId: try movie.requireID(),
          tagId: try tag.requireID(),
          addedByAutoTag: addedByAutoTag
        )
        try await movieTag.save(on: fluent.db())
      }
    } else {
      let existingTagIds = try await MovieTag.query(on: fluent.db())
        .filter(\.$movie.$id == movie.requireID())
        .with(\.$tag)
        .all()
        .map { try $0.tag.requireID() }

      for tag in tags {
        let tagId = try tag.requireID()
        if !existingTagIds.contains(tagId) {
          let movieTag = MovieTag(
            movieId: try movie.requireID(),
            tagId: tagId,
            addedByAutoTag: addedByAutoTag
          )
          try await movieTag.save(on: fluent.db())
        }
      }
    }

    try await updateTagUsageCounts(for: validSlugs)

    let updatedMovie = try await Movie.query(on: fluent.db())
      .filter(\.$id == movie.requireID())
      .with(\.$tags)
      .first()!

    // A human just touched the tag set — any outstanding weak-review row is stale.
    if !addedByAutoTag {
      let pendingRows = try await TagSuggestion.query(on: fluent.db())
        .filter(\.$jellyfinId == updatedMovie.jellyfinId)
        .filter(\.$status == "pending")
        .all()
      for row in pendingRows {
        row.status = "approved"
        row.resolvedAt = Date()
        try await row.save(on: fluent.db())
      }
    }

    return ClientTagEntry(
      jellyfinId: updatedMovie.jellyfinId,
      tags: updatedMovie.tags.map { $0.slug },
      needsReview: false
    )
  }

  /// Remove the specific tags that an auto-tag run added to a movie. Admin-added rows
  /// (addedByAutoTag=false) are left untouched by the filter.
  func removeAutoTags(jellyfinId: String, tagSlugs: [String]) async throws {
    guard !tagSlugs.isEmpty else { return }
    let movie = try await Movie.query(on: fluent.db())
      .filter(\.$jellyfinId == jellyfinId)
      .first()
      .unwrap(orError: MovieServiceError.movieNotFound(jellyfinId))
    let movieId = try movie.requireID()

    for slug in tagSlugs {
      guard
        let tag = try await Tag.query(on: fluent.db()).filter(\.$slug == slug).first()
      else { continue }
      try await MovieTag.query(on: fluent.db())
        .filter(\.$movie.$id == movieId)
        .filter(\.$tag.$id == tag.requireID())
        .filter(\.$addedByAutoTag == true)
        .delete()
    }

    try await updateTagUsageCounts(for: tagSlugs)
  }

  // MARK: - Clients API helpers

  /// Movies with a given mood tag, returned as just Jellyfin IDs.
  func getClientJellyfinIds(withTag tagSlug: String) async throws -> [String] {
    guard config.moodBuckets[tagSlug] != nil else {
      throw MovieServiceError.tagNotFound(tagSlug)
    }
    let tag = try await Tag.query(on: fluent.db())
      .filter(\.$slug == tagSlug)
      .first()
      .unwrap(orError: MovieServiceError.tagNotFound(tagSlug))
    let movies = try await Movie.query(on: fluent.db())
      .join(MovieTag.self, on: \Movie.$id == \MovieTag.$movie.$id)
      .filter(MovieTag.self, \.$tag.$id == tag.requireID())
      .sort(\.$jellyfinId)
      .all()
    return movies.map { $0.jellyfinId }
  }

  /// Full {jellyfinId, [tagSlugs], needsReview} bulk join for clients.
  func getClientTagMap() async throws -> [ClientTagEntry] {
    let movies = try await Movie.query(on: fluent.db())
      .with(\.$tags)
      .all()
    let pendingIds = try await pendingReviewJellyfinIds()
    return movies.map { m in
      ClientTagEntry(
        jellyfinId: m.jellyfinId,
        tags: m.tags.map { $0.slug },
        needsReview: pendingIds.contains(m.jellyfinId)
      )
    }
  }

  /// Tags for a single Jellyfin id.
  func getClientTags(jellyfinId: String) async throws -> ClientTagEntry {
    let movie = try await Movie.query(on: fluent.db())
      .filter(\.$jellyfinId == jellyfinId)
      .with(\.$tags)
      .first()
      .unwrap(orError: MovieServiceError.movieNotFound(jellyfinId))
    let isPending = try await TagSuggestion.query(on: fluent.db())
      .filter(\.$jellyfinId == jellyfinId)
      .filter(\.$status == "pending")
      .first() != nil
    return ClientTagEntry(
      jellyfinId: movie.jellyfinId,
      tags: movie.tags.map { $0.slug },
      needsReview: isPending
    )
  }

  private func pendingReviewJellyfinIds() async throws -> Set<String> {
    let rows = try await TagSuggestion.query(on: fluent.db())
      .filter(\.$status == "pending")
      .field(\.$jellyfinId)
      .all()
    return Set(rows.map { $0.jellyfinId })
  }

  /// Random mood pick (excluding provided slugs) with all jellyfin IDs for that mood.
  func getRandomMoodSection(excluding excluded: [String]) async throws -> ClientMoodBlock? {
    let allMoods = Array(config.moodBuckets.keys)
    let excludeSet = Set(excluded.compactMap { $0.isEmpty ? nil : $0 })
    var pool = allMoods.filter { !excludeSet.contains($0) }
    if pool.isEmpty { pool = allMoods }
    guard let slug = pool.randomElement() else { return nil }
    let title = config.moodBuckets[slug]?.title ?? slug
    let ids = (try? await getClientJellyfinIds(withTag: slug)) ?? []
    return ClientMoodBlock(slug: slug, title: title, jellyfinIds: ids)
  }

  /// Deterministic daily featured mood (djb2 hash of yyyy-MM-dd).
  func getFeaturedMoodSection(excluding excluded: [String]) async throws -> ClientMoodBlock? {
    let allMoods = Array(config.moodBuckets.keys)
    let excludeSet = Set(excluded.compactMap { $0.isEmpty ? nil : $0 })
    var pool = allMoods.filter { !excludeSet.contains($0) }
    if pool.isEmpty { pool = allMoods }
    guard !pool.isEmpty else { return nil }
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd"
    let seed = df.string(from: Date())
    func djb2(_ s: String) -> Int {
      var h = 5381
      for u in s.unicodeScalars { h = ((h << 5) &+ h) &+ Int(u.value) }
      return abs(h)
    }
    let slug = Array(pool.sorted())[djb2(seed) % pool.count]
    let title = config.moodBuckets[slug]?.title ?? slug
    let ids = (try? await getClientJellyfinIds(withTag: slug)) ?? []
    return ClientMoodBlock(slug: slug, title: title, jellyfinIds: ids)
  }

  // MARK: - Maintenance
  func clearAllMovies() async throws {
    try await MovieTag.query(on: fluent.db()).delete()
    try await Movie.query(on: fluent.db()).delete()
    let allTags = try await Tag.query(on: fluent.db()).all()
    for tag in allTags {
      tag.usageCount = 0
      try await tag.save(on: fluent.db())
    }
    logger.info("Cleared all movies and reset tag usage counts")
  }

  // MARK: - Export/Import
  func exportTagsMap() async throws -> [String: ExportMovieTags] {
    let movies = try await Movie.query(on: fluent.db())
      .with(\.$tags)
      .all()
    var map: [String: ExportMovieTags] = [:]
    for m in movies {
      map[m.jellyfinId] = ExportMovieTags(tags: m.tags.map { $0.slug })
    }
    return map
  }

  func importTagsMap(_ map: [String: ExportMovieTags], replaceAll: Bool = true) async throws {
    for (jellyfinId, payload) in map {
      do {
        _ = try await updateMovieTags(
          movieId: jellyfinId, tagSlugs: payload.tags, replaceAll: replaceAll)
      } catch {
        logger.error("Failed to import tags for jellyfinId=\(jellyfinId): \(error)")
      }
    }
    let uniqueSlugs = Array(Set(map.values.flatMap { $0.tags }))
    try await updateTagUsageCounts(for: uniqueSlugs)
  }

  // MARK: - Jellyfin Sync (ID-only reconciliation)

  func syncWithJellyfin(fullSync: Bool = false) async throws -> SyncStatusResponse {
    guard !isSyncing else {
      throw MovieServiceError.syncAlreadyRunning
    }

    isSyncing = true
    let startTime = Date()
    var stats = SyncStats()

    defer {
      isSyncing = false
      lastSyncAt = startTime
      lastSyncDuration = Date().timeIntervalSince(startTime)
      lastSyncStats = stats
    }

    logger.info("Starting Jellyfin sync (full: \(fullSync))")

    do {
      var jellyfinIdsList: [String]
      do {
        jellyfinIdsList = try await jellyfinService.fetchAllMovieIds()
      } catch let e as JellyfinError {
        switch e {
        case .httpError(let code, _):
          if code == 401 {
            let refreshed = try await attemptAutoLoginAndUpdate()
            if refreshed {
              jellyfinIdsList = try await jellyfinService.fetchAllMovieIds()
            } else {
              throw e
            }
          } else {
            throw e
          }
        default:
          throw e
        }
      }
      stats.moviesFound = jellyfinIdsList.count
      self.lastSyncStats = stats

      let now = Date()
      let jellyfinIds = Set(jellyfinIdsList)

      // Upsert movies: insert new IDs, bump last_seen_at on existing.
      // New insertions fire-and-forget an auto-tag suggestion into the queue.
      for jid in jellyfinIdsList {
        do {
          if let existing = try await Movie.query(on: fluent.db())
            .filter(\.$jellyfinId == jid)
            .first()
          {
            existing.lastSeenAt = now
            try await existing.save(on: fluent.db())
            stats.moviesUpdated += 1
          } else {
            let movie = Movie(jellyfinId: jid, lastSeenAt: now)
            try await movie.save(on: fluent.db())
            stats.moviesUpdated += 1
            if config.enableAutoTagging {
              suggestionService?.enqueueInBackground(jellyfinId: jid)
            }
          }
          self.lastSyncStats = stats
        } catch {
          stats.errors.append("Failed to sync movie \(jid): \(error)")
          logger.error("Failed to sync movie \(jid): \(error)")
          self.lastSyncStats = stats
        }
      }

      // Delete movies that no longer exist in Jellyfin
      do {
        let allDbMovies = try await Movie.query(on: fluent.db()).all()
        let orphaned = allDbMovies.filter { !jellyfinIds.contains($0.jellyfinId) }
        if !orphaned.isEmpty {
          logger.info("Deleting \(orphaned.count) movies no longer present in Jellyfin")
        }
        for movie in orphaned {
          do {
            let jid = movie.jellyfinId
            try await movie.delete(on: fluent.db())
            stats.moviesDeleted += 1
            self.lastSyncStats = stats
            logger.info("Deleted movie (jellyfinId=\(jid)) from local DB")
          } catch {
            stats.errors.append("Failed to delete movie \(movie.jellyfinId): \(error)")
            logger.error("Failed to delete orphaned movie \(movie.jellyfinId): \(error)")
            self.lastSyncStats = stats
          }
        }
        let allTags = try await Tag.query(on: fluent.db()).all()
        let allSlugs = allTags.map { $0.slug }
        try await updateTagUsageCounts(for: allSlugs)
      } catch {
        stats.errors.append("Cleanup step failed: \(error)")
        logger.error("Cleanup of orphaned movies failed: \(error)")
      }

      logger.info(
        "Jellyfin sync completed: \(stats.moviesFound) found, \(stats.moviesUpdated) updated, \(stats.moviesDeleted) deleted"
      )
    } catch {
      stats.errors.append("Sync failed: \(error)")
      logger.error("Jellyfin sync failed: \(error)")
      throw error
    }

    return SyncStatusResponse(
      isRunning: false,
      lastSyncAt: startTime,
      lastSyncDuration: Date().timeIntervalSince(startTime),
      moviesFound: stats.moviesFound,
      moviesUpdated: stats.moviesUpdated,
      moviesDeleted: stats.moviesDeleted,
      errors: stats.errors
    )
  }

  func getSyncStatus() async throws -> SyncStatusResponse {
    return SyncStatusResponse(
      isRunning: isSyncing,
      lastSyncAt: lastSyncAt,
      lastSyncDuration: lastSyncDuration,
      moviesFound: lastSyncStats.moviesFound,
      moviesUpdated: lastSyncStats.moviesUpdated,
      moviesDeleted: lastSyncStats.moviesDeleted,
      errors: lastSyncStats.errors
    )
  }

  func testJellyfinConnection() async throws -> ConnectionTestResponse {
    do {
      let isConnected = try await jellyfinService.testConnection()
      if isConnected {
        let serverInfo = try await jellyfinService.getServerInfo()
        return ConnectionTestResponse(success: true, serverInfo: serverInfo, error: nil)
      } else {
        return ConnectionTestResponse(
          success: false, serverInfo: nil, error: "Authentication failed")
      }
    } catch {
      return ConnectionTestResponse(
        success: false, serverInfo: nil, error: error.localizedDescription)
    }
  }

  // MARK: - Private Helpers

  private func getMovieEntity(id: String) async throws -> Movie {
    if let uuid = UUID(uuidString: id) {
      return try await Movie.query(on: fluent.db())
        .filter(\.$id == uuid)
        .first()
        .unwrap(orError: MovieServiceError.movieNotFound(id))
    } else {
      return try await Movie.query(on: fluent.db())
        .filter(\.$jellyfinId == id)
        .first()
        .unwrap(orError: MovieServiceError.movieNotFound(id))
    }
  }

  private func validateTagSlugs(_ slugs: [String]) throws -> [String] {
    var validSlugs: [String] = []
    for slug in slugs {
      guard config.moodBuckets[slug] != nil else {
        throw MovieServiceError.tagNotFound(slug)
      }
      validSlugs.append(slug)
    }
    return validSlugs
  }

  private func getOrCreateTag(slug: String) async throws -> Tag {
    if let existing = try await Tag.query(on: fluent.db()).filter(\.$slug == slug).first() {
      return existing
    }
    guard let bucket = config.moodBuckets[slug] else {
      throw MovieServiceError.tagNotFound(slug)
    }
    let tag = Tag(slug: slug, title: bucket.title, description: bucket.description)
    try await tag.save(on: fluent.db())
    return tag
  }

  private func updateTagUsageCounts(for slugs: [String]) async throws {
    for slug in slugs {
      if let tag = try await Tag.query(on: fluent.db()).filter(\.$slug == slug).first() {
        let count = try await MovieTag.query(on: fluent.db())
          .filter(\.$tag.$id == tag.requireID())
          .count()
        tag.usageCount = count
        try await tag.save(on: fluent.db())
      }
    }
  }
}

// MARK: - Supporting Types

private struct SyncStats {
  var moviesFound: Int = 0
  var moviesUpdated: Int = 0
  var moviesDeleted: Int = 0
  var errors: [String] = []
}

enum MovieServiceError: Error, CustomStringConvertible {
  case movieNotFound(String)
  case tagNotFound(String)
  case syncAlreadyRunning

  var description: String {
    switch self {
    case .movieNotFound(let id):
      return "Movie not found: \(id)"
    case .tagNotFound(let slug):
      return "Tag not found: \(slug)"
    case .syncAlreadyRunning:
      return "Sync is already running"
    }
  }
}

// MARK: - LLM context

/// Plain-struct movie context for LLM prompts; decouples LLMService from the slim DB Movie model.
struct MovieContext {
  let title: String
  let originalTitle: String?
  let year: Int?
  let overview: String?
  let runtimeMinutes: Int?
  let director: String?
  let genres: [String]
  let cast: [String]

  init(from item: BaseItemDto) {
    self.title = item.name ?? ""
    self.originalTitle = item.originalTitle
    self.year = item.productionYear
    self.overview = item.overview
    self.runtimeMinutes = item.runTimeTicks.map { Int($0 / 600_000_000) }
    self.director = item.people?.first { ($0.type ?? "").lowercased() == "director" }?.name
    self.genres = item.genres ?? []
    self.cast = (item.people ?? [])
      .filter { ($0.type ?? "").lowercased() == "actor" }
      .compactMap { $0.name }
  }
}
