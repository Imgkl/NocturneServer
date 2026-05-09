import AsyncHTTPClient
import FluentKit
import Foundation
import HTTPTypes
import Hummingbird
import Logging
import NIOCore

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

final class APIRoutes: @unchecked Sendable {
  let movieService: MovieService
  let suggestionService: SuggestionService
  let config: NocturneConfiguration
  let logger = Logger(label: "APIRoutes")
  let httpClient: HTTPClient
  let posterCache: PosterCache?

  init(
    movieService: MovieService,
    suggestionService: SuggestionService,
    config: NocturneConfiguration,
    httpClient: HTTPClient
  ) {
    self.movieService = movieService
    self.suggestionService = suggestionService
    self.config = config
    self.httpClient = httpClient
    self.posterCache = (try? PosterCache(
      dir: config.posterCacheDir,
      maxBytes: config.posterCacheMaxBytes
    ))
    if self.posterCache == nil {
      logger.warning("PosterCache init failed; poster endpoint will proxy without caching")
    }
  }

  func addRoutes(to router: Router<BasicRequestContext>) {
    // Health check
    router.get("/health") { _, _ in Response(status: .ok) }
    // Version endpoint
    router.get("/version") { _, _ in
      struct VersionResponse: Codable { let version: String }
      let v = ProcessInfo.processInfo.environment["NOCTURNE_VERSION"] ?? "dev"
      return try jsonResponse(VersionResponse(version: v))
    }

    let api = router.group("api/v1")

    addMoodRoutes(to: api)
    addMovieRoutes(to: api)
    addTagRoutes(to: api)
    addSyncRoutes(to: api)
    addSettingsRoutes(to: api)
    addImportExportRoutes(to: api)
    addClientRoutes(to: api)
    addAdminRoutes(to: api)
    addJellyfinDiscoveryRoutes(to: api)
    addOnboardingRoutes(to: api)
  }

  // MARK: - Mood Routes (admin needs the bucket list for display names)

  private func addMoodRoutes(to router: RouterGroup<BasicRequestContext>) {
    let moods = router.group("moods")

    moods.get { request, context in
      try jsonResponse(
        MoodBucketsResponse(
          moods: self.movieService.config.moodBuckets
        ))
    }
  }

  // MARK: - Movie Routes (admin tag editor + auto-tag queue)

  private func addMovieRoutes(to router: RouterGroup<BasicRequestContext>) {
    let movies = router.group("movies")

    movies.put(":id/tags") { request, context in
      let movieId = try context.parameters.require("id")
      let updateRequest = try await request.decode(
        as: UpdateMovieTagsRequest.self, context: context)
      try updateRequest.validate()

      return try jsonResponse(
        try await self.movieService.updateMovieTags(
          jellyfinId: String(movieId),
          tagSlugs: updateRequest.tagSlugs,
          replaceAll: updateRequest.replaceAll
        ))
    }

    // Always routes through the suggestion queue; never auto-applies.
    // Body is ignored — prompt/provider come from server config.
    movies.post(":id/auto-tag") { request, context in
      let jellyfinId = try context.parameters.require("id")
      let sugg = try await self.suggestionService.enqueue(jellyfinId: String(jellyfinId))
      return try jsonResponse(TagSuggestionResponse(sugg))
    }

    // Poster proxy: fetches from Jellyfin on cache miss, serves from disk on hit.
    // Sizes: thumb=200w, medium=400w, full=original.
    movies.get(":id/poster") { request, context -> Response in
      let jellyfinId = String(try context.parameters.require("id"))
      let size = request.uri.queryParameters["size"].map { String($0) } ?? "medium"
      let fillWidth: Int?
      switch size {
      case "thumb":  fillWidth = 200
      case "full":   fillWidth = nil
      default:       fillWidth = 400  // "medium" and unknown
      }
      let cacheKey = "\(jellyfinId)-\(size)"

      // Cache hit
      if let entry = self.posterCache?.get(key: cacheKey) {
        return Self.imageResponse(
          data: entry.data,
          contentType: entry.contentType,
          cacheHit: true
        )
      }

      // Miss — fetch from Jellyfin
      let (data, contentType): (Data, String)
      do {
        (data, contentType) = try await self.movieService.jellyfinService
          .fetchPosterBytes(itemId: jellyfinId, fillWidth: fillWidth)
      } catch {
        self.logger.info("Poster fetch failed for \(jellyfinId) size=\(size): \(error)")
        throw HTTPError(.notFound)
      }

      self.posterCache?.set(key: cacheKey, data: data, contentType: contentType)
      return Self.imageResponse(data: data, contentType: contentType, cacheHit: false)
    }
  }

  // MARK: - Tag Routes (per-tag AI refinement)
  private func addTagRoutes(to router: RouterGroup<BasicRequestContext>) {
    let tags = router.group("tags")

    // POST /api/v1/tags/:slug/refine — start a per-tag refinement pass against every movie
    // currently carrying this tag via auto-apply. Shares the long-running-worker mutex with
    // the backfill flow.
    tags.post(":slug/refine") { request, context in
      let slug = String(try context.parameters.require("slug"))
      do {
        let status = try await self.suggestionService.startTagRefinement(tagSlug: slug)
        return try jsonResponse(status)
      } catch SuggestionError.tagNotFound {
        throw HTTPError(.badRequest)
      } catch SuggestionError.backfillInProgress {
        throw HTTPError(.conflict)
      }
    }

    tags.get(":slug/refine/status") { request, context in
      let status = await self.suggestionService.getTagRefinementStatus()
      return try jsonResponse(status)
    }

    tags.post(":slug/refine/cancel") { request, context in
      await self.suggestionService.cancelTagRefinement()
      let status = await self.suggestionService.getTagRefinementStatus()
      return try jsonResponse(status)
    }
  }

  private static func imageResponse(data: Data, contentType: String, cacheHit: Bool) -> Response {
    let body = responseBody(from: data)
    let headers = HTTPFields([
      HTTPField(name: .contentType, value: contentType),
      HTTPField(name: .cacheControl, value: "public, max-age=604800, immutable"),
      HTTPField(name: HTTPField.Name("X-Nocturne-Cache")!, value: cacheHit ? "hit" : "miss"),
    ])
    return Response(status: .ok, headers: headers, body: body)
  }

  // MARK: - Sync Routes

  private func addSyncRoutes(to router: RouterGroup<BasicRequestContext>) {
    let sync = router.group("sync")

    sync.post("jellyfin") { request, context in
      let store = SettingsStore(db: self.movieService.fluent.db(), logger: self.logger)
      try await store.ensureTable()
      if let url = try await store.get("jellyfin_url"),
        let api = try await store.get("jellyfin_api_key"),
        let uid = try await store.get("jellyfin_user_id")
      {
        self.movieService.reconfigureJellyfin(baseURL: url, apiKey: api, userId: uid)
      }
      let fullSync = request.uri.queryParameters["full"].map { String($0) == "true" } ?? false
      return try jsonResponse(try await self.movieService.syncWithJellyfin(fullSync: fullSync))
    }

    sync.get("status") { request, context in
      return try jsonResponse(try await self.movieService.getSyncStatus())
    }

    sync.post("test-connection") { request, context in
      return try jsonResponse(try await self.movieService.testJellyfinConnection())
    }
  }

  // MARK: - Jellyfin Discovery (UDP broadcast on :7359)

  private func addJellyfinDiscoveryRoutes(to router: RouterGroup<BasicRequestContext>) {
    let jellyfin = router.group("jellyfin")
    struct DiscoveryResponse: Codable { let servers: [JellyfinDiscovery.Server] }

    jellyfin.post("discover") { request, context in
      let timeout = self.config.jellyfinDiscoveryTimeoutMs
      do {
        let servers = try await JellyfinDiscovery.discover(timeoutMs: timeout)
        return try jsonResponse(DiscoveryResponse(servers: servers))
      } catch {
        self.logger.warning("Jellyfin discovery failed: \(error)")
        return try jsonResponse(DiscoveryResponse(servers: []))
      }
    }
  }

  // MARK: - Import/Export Routes
  private func addImportExportRoutes(to router: RouterGroup<BasicRequestContext>) {
    let data = router.group("data")

    data.get("export") { request, context in
      let map = try await self.movieService.exportTagsMap()
      return try jsonResponse(map)
    }

    struct ImportPayload: Codable {
      let replaceAll: Bool?
      let map: [String: ExportMovieTags]
    }

    data.post("import") { request, context in
      let payload = try await request.decode(as: ImportPayload.self, context: context)
      try await self.movieService.importTagsMap(payload.map, replaceAll: payload.replaceAll ?? true)
      return try jsonResponse(["success": true])
    }
  }

  // MARK: - Clients Routes (ID-only surface for mobile/desktop clients)
  private func addClientRoutes(to router: RouterGroup<BasicRequestContext>) {
    let clients = router.group("clients")

    clients.get("ping") { request, context in
      return try jsonResponse(SuccessResponse(success: true))
    }

    let moods = clients.group("moods")
    moods.get { request, context in
      struct ClientMoods: Codable { let moods: [String: MoodBucket] }
      return try jsonResponse(ClientMoods(moods: self.movieService.config.moodBuckets))
    }

    moods.get(":slug") { request, context in
      let slug = try context.parameters.require("slug")
      guard let mood = self.movieService.config.moodBuckets[String(slug)] else {
        throw HTTPError(.notFound)
      }
      struct BucketResponse: Codable {
        let slug: String
        let mood: MoodBucket
      }
      return try jsonResponse(BucketResponse(slug: String(slug), mood: mood))
    }

    moods.get(":slug/movies") { request, context in
      let slug = try context.parameters.require("slug")
      let ids = try await self.movieService.getClientJellyfinIds(withTag: String(slug))
      return try jsonResponse(
        ClientMoodMoviesResponse(slug: String(slug), jellyfinIds: ids))
    }

    clients.get("tags") { request, context in
      let items = try await self.movieService.getClientTagMap()
      return try jsonResponse(ClientTagsListResponse(items: items))
    }

    // POST /api/v1/clients/tags/batch — tags for a caller-supplied set of Jellyfin IDs.
    // Preserves input order; drops unknown IDs. Capped at 500 per call.
    struct BatchTagsRequest: Codable { let jellyfinIds: [String] }
    clients.post("tags/batch") { request, context in
      let payload = try await request.decode(as: BatchTagsRequest.self, context: context)
      guard payload.jellyfinIds.count <= 500 else { throw HTTPError(.badRequest) }
      let items = try await self.movieService.getClientTagsBatch(
        jellyfinIds: payload.jellyfinIds)
      return try jsonResponse(ClientTagsListResponse(items: items))
    }

    let clientMovies = clients.group("movies")
    clientMovies.get(":jellyfinId/tags") { request, context in
      let jellyfinId = try context.parameters.require("jellyfinId")
      return try jsonResponse(
        try await self.movieService.getClientTags(jellyfinId: String(jellyfinId)))
    }

    clients.get("home") { request, context in
      let headerName = HTTPField.Name("X-Mood-Exclude")
      let excludeHeader = request.headers.first { $0.name == headerName }?.value
      let excludedMoods: [String] =
        excludeHeader.map { value in
          value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        } ?? []

      async let randomTask = self.movieService.getRandomMoodSection(excluding: excludedMoods)
      async let featuredTask = self.movieService.getFeaturedMoodSection(excluding: excludedMoods)
      let (random, featured) = try await (randomTask, featuredTask)
      return try jsonResponse(
        ClientHomePayload(randomMood: random, featuredMood: featured))
    }

    // OMDb ratings proxy — keeps the key off clients and shares a 15-day cache
    struct OmdbRatingsResponse: Codable { let ratings: [OmdbRating] }
    struct RawOmdbResponse: Codable {
      let Ratings: [OmdbRating]?
      let Response: String?
    }

    clients.get("omdb/ratings") { request, context in
      let imdbId =
        request.uri.queryParameters["imdbId"].map { String($0) }?.trimmingCharacters(
          in: .whitespacesAndNewlines) ?? ""

      guard !imdbId.isEmpty else { return try jsonResponse(OmdbRatingsResponse(ratings: [])) }

      let store = SettingsStore(db: self.movieService.fluent.db(), logger: self.logger)
      try await store.ensureTable()
      let savedKey = try await store.get("omdb_api_key") ?? (self.config.omdbApiKey ?? "")
      guard !savedKey.isEmpty else { return try jsonResponse(OmdbRatingsResponse(ratings: [])) }

      let cache = OmdbCacheStore(db: self.movieService.fluent.db(), logger: self.logger)
      try await cache.ensureTable()
      if let cached = try await cache.get(imdbId: imdbId) {
        let fifteenDays: TimeInterval = 15 * 24 * 60 * 60
        if Date().timeIntervalSince(cached.fetchedAt) < fifteenDays {
          return try jsonResponse(OmdbRatingsResponse(ratings: cached.ratings))
        }
      }

      do {
        let url = "http://www.omdbapi.com/?apikey=\(savedKey)&i=\(imdbId)"
        let response = try await self.httpClient.get(url: url).get()
        guard var body = response.body else {
          return try jsonResponse(OmdbRatingsResponse(ratings: []))
        }
        let data = body.readData(length: body.readableBytes) ?? Data()
        let raw = try JSONDecoder().decode(RawOmdbResponse.self, from: data)
        let ok = (raw.Response?.lowercased() == "true")
        let ratings = ok ? (raw.Ratings ?? []) : []
        if ok {
          try await cache.set(imdbId: imdbId, ratings: ratings)
        }
        return try jsonResponse(OmdbRatingsResponse(ratings: ratings))
      } catch {
        self.logger.warning("OMDb fetch failed: \(String(describing: error))")
        return try jsonResponse(OmdbRatingsResponse(ratings: []))
      }
    }
  }

  // MARK: - Admin Routes (suggestion queue + movies proxy)
  private func addAdminRoutes(to router: RouterGroup<BasicRequestContext>) {
    let admin = router.group("admin")

    // GET /admin/suggestions?status=pending
    admin.get("suggestions") { request, context in
      let statusParam = request.uri.queryParameters["status"].map { String($0) } ?? "pending"
      let rows: [TagSuggestion]
      if statusParam == "pending" {
        rows = try await self.suggestionService.listPending()
      } else {
        rows = try await TagSuggestion.query(on: self.movieService.fluent.db())
          .filter(\.$status == statusParam)
          .sort(\.$createdAt, DatabaseQuery.Sort.Direction.descending)
          .all()
      }
      return try jsonResponse(
        SuggestionListResponse(items: rows.map(TagSuggestionResponse.init)))
    }

    // POST /admin/suggestions/:id/approve
    // Optional body: { "tags": ["slug1", "slug2"] } — when present, overrides the suggested
    // tags with the reviewer's edited set before approving.
    struct ApproveBody: Codable { let tags: [String]? }
    admin.post("suggestions/:id/approve") { request, context in
      let idStr = try context.parameters.require("id")
      guard let uuid = UUID(uuidString: String(idStr)) else {
        throw HTTPError(.badRequest)
      }
      let overrideTags = try? await request.decode(as: ApproveBody.self, context: context).tags
      let sugg = try await self.suggestionService.approve(uuid, overrideTags: overrideTags)
      return try jsonResponse(TagSuggestionResponse(sugg))
    }

    // POST /admin/suggestions/:id/reject
    admin.post("suggestions/:id/reject") { request, context in
      let idStr = try context.parameters.require("id")
      guard let uuid = UUID(uuidString: String(idStr)) else {
        throw HTTPError(.badRequest)
      }
      let sugg = try await self.suggestionService.reject(uuid)
      return try jsonResponse(TagSuggestionResponse(sugg))
    }

    // POST /admin/suggestions/regenerate/:jellyfinId
    admin.post("suggestions/regenerate/:jellyfinId") { request, context in
      let jid = try context.parameters.require("jellyfinId")
      let sugg = try await self.suggestionService.regenerate(jellyfinId: String(jid))
      return try jsonResponse(TagSuggestionResponse(sugg))
    }

    // POST /admin/auto-tag/backfill — kick off a background worker that auto-tags every movie
    // with no tags and no pending suggestion. Idempotent.
    admin.post("auto-tag/backfill") { request, context in
      let status = try await self.suggestionService.startBackfill()
      return try jsonResponse(status)
    }

    // GET /admin/auto-tag/backfill/status — current progress snapshot.
    admin.get("auto-tag/backfill/status") { request, context in
      let status = await self.suggestionService.getBackfillStatus()
      return try jsonResponse(status)
    }

    // POST /admin/auto-tag/reprocess-all — clear every movie's tags, supersede pending
    // suggestions, then re-run the auto-tagger against the whole library. Destructive.
    admin.post("auto-tag/reprocess-all") { request, context in
      let status = try await self.suggestionService.startReprocessAll()
      return try jsonResponse(status)
    }

    // POST /admin/auto-tag/cancel — request cancellation of the in-flight worker. The worker
    // checks this flag before each enqueue and bails cleanly. Returns the current status so
    // the frontend can immediately reflect the cancelled state.
    admin.post("auto-tag/cancel") { request, context in
      await self.suggestionService.cancelBackfill()
      let status = await self.suggestionService.getBackfillStatus()
      return try jsonResponse(status)
    }

    // GET /admin/movies?q&limit&offset — live Jellyfin fetch + local tag join + needs-review flag
    struct AdminMovie: Codable {
      let jellyfinId: String
      let title: String
      let year: Int?
      let posterUrl: String?
      let tags: [String]
      let needsReview: Bool
    }
    struct AdminMoviesResponse: Codable {
      let items: [AdminMovie]
      let totalCount: Int
      let offset: Int
      let limit: Int
    }
    admin.get("movies") { request, context in
      let q = request.uri.queryParameters["q"].map { String($0).lowercased() } ?? ""
      let limit = request.uri.queryParameters["limit"].flatMap { Int(String($0)) } ?? 100
      let offset = request.uri.queryParameters["offset"].flatMap { Int(String($0)) } ?? 0

      let live = try await self.movieService.jellyfinService.fetchAllMovies()

      // Local tag map
      let localMovies = try await Movie.query(on: self.movieService.fluent.db())
        .with(\.$tags)
        .all()
      var tagsByJellyfinId: [String: [String]] = [:]
      for m in localMovies {
        tagsByJellyfinId[m.jellyfinId] = m.tags.map { $0.slug }
      }
      let pending = try await self.suggestionService.pendingJellyfinIds()

      let filtered = live.filter { item in
        guard q.isEmpty else {
          let haystack = (item.name ?? "").lowercased() + " "
            + (item.originalTitle ?? "").lowercased()
          return haystack.contains(q)
        }
        return true
      }
      let totalCount = filtered.count
      let paged = Array(filtered.dropFirst(offset).prefix(limit))

      let items: [AdminMovie] = paged.map { item in
        let jid = item.id ?? ""
        return AdminMovie(
          jellyfinId: jid,
          title: item.name ?? "",
          year: item.productionYear,
          posterUrl: self.movieService.jellyfinService.getImageUrl(for: item, imageType: .primary),
          tags: tagsByJellyfinId[jid] ?? [],
          needsReview: pending.contains(jid)
        )
      }

      return try jsonResponse(
        AdminMoviesResponse(items: items, totalCount: totalCount, offset: offset, limit: limit))
    }

    // GET /admin/lan-address — best-effort LAN-routable URL the mobile app
    // can hit. Used by the "Link mobile app" QR code in the web UI; the
    // browser's `window.location.origin` is useless to a phone when the
    // user is browsing via localhost.
    struct LANAddressResponse: Codable { let url: String? }
    admin.get("lan-address") { _, _ in
      let host = Self.bestLANHost()
      let url = host.map { "http://\($0):\(self.config.port)" }
      return try jsonResponse(LANAddressResponse(url: url))
    }
  }

  /// Picks a LAN-routable IPv4 address from the host's network
  /// interfaces. Prefers `en*` (Wi-Fi/ethernet on macOS) over `eth*`/`wlan*`
  /// (Linux/Docker), rejects loopback (`127/8`) and link-local
  /// (`169.254/16`). Returns nil if nothing usable is found — the caller
  /// falls back to `window.location.origin`.
  private static func bestLANHost() -> String? {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return nil }
    defer { freeifaddrs(head) }

    var candidates: [(name: String, address: String)] = []
    var ptr: UnsafeMutablePointer<ifaddrs>? = first
    while let cur = ptr {
      defer { ptr = cur.pointee.ifa_next }
      // IFF_UP / IFF_LOOPBACK come through as Int on Glibc, Int32 on
      // Darwin — normalise both sides to Int32 for a portable bitmask.
      let flags = Int32(cur.pointee.ifa_flags)
      guard (flags & Int32(IFF_UP)) != 0, (flags & Int32(IFF_LOOPBACK)) == 0,
        let sa = cur.pointee.ifa_addr,
        sa.pointee.sa_family == sa_family_t(AF_INET)
      else { continue }

      // sockaddr length: IPv4 is fixed-size; sa_len isn't portable to Linux.
      let saLen = socklen_t(MemoryLayout<sockaddr_in>.size)
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let result = getnameinfo(
        sa, saLen,
        &host, socklen_t(host.count),
        nil, 0, NI_NUMERICHOST
      )
      guard result == 0 else { continue }
      let address = String(cString: host)
      // Reject link-local AutoIP.
      if address.hasPrefix("169.254.") { continue }

      let name = String(cString: cur.pointee.ifa_name)
      candidates.append((name: name, address: address))
    }

    // en* (macOS Wi-Fi/ethernet) first, then eth*/wlan* (Linux/Docker host),
    // then anything else. Within a tier, first match wins.
    func tier(_ name: String) -> Int {
      if name.hasPrefix("en") { return 0 }
      if name.hasPrefix("eth") || name.hasPrefix("wlan") { return 1 }
      return 2
    }
    return candidates.min { tier($0.name) < tier($1.name) }?.address
  }

  // MARK: - Settings Routes (BYOK)
  private func addSettingsRoutes(to router: RouterGroup<BasicRequestContext>) {
    let settings = router.group("settings")

    struct KeysPayload: Codable {
      let anthropic_api_key: String?
      let omdb_api_key: String?
      let enable_auto_tagging: Bool?
    }

    settings.post("keys") { request, context in
      let payload = try await request.decode(as: KeysPayload.self, context: context)
      if let v = payload.anthropic_api_key { self.config.anthropicApiKey = v }
      if let v = payload.omdb_api_key { self.config.omdbApiKey = v }
      if let v = payload.enable_auto_tagging { self.config.enableAutoTagging = v }
      let store = SettingsStore(db: self.movieService.fluent.db(), logger: self.logger)
      try await store.ensureTable()
      try await store.set("anthropic_api_key", self.config.anthropicApiKey ?? "")
      try await store.set("omdb_api_key", self.config.omdbApiKey ?? "")
      try await store.set("enable_auto_tagging", self.config.enableAutoTagging ? "true" : "false")
      return try jsonResponse(["success": true])
    }

    settings.post("clear-movies") { request, context in
      try await self.movieService.clearAllMovies()
      return try jsonResponse(["success": true])
    }

    // Single jellyfin-config endpoint — accepts either creds (url+username+password, server logs
    // in) or a pre-existing token (url+apiKey+userId). Persists, re-keys the runtime client.
    struct JellyfinPayload: Codable {
      let jellyfin_url: String?
      let jellyfin_api_key: String?
      let jellyfin_user_id: String?
      let jellyfin_username: String?
      let jellyfin_password: String?
    }

    struct JellyfinSaveResponse: Codable {
      let success: Bool
      let error: String?
      let userId: String?
      let serverName: String?
      let version: String?
      let localAddress: String?
    }

    settings.post("jellyfin") { request, context in
      let payload = try await request.decode(as: JellyfinPayload.self, context: context)
      let store = SettingsStore(db: self.movieService.fluent.db(), logger: self.logger)
      try await store.ensureTable()

      if let url = payload.jellyfin_url,
        let username = payload.jellyfin_username,
        let password = payload.jellyfin_password
      {
        // Creds path — log in to Jellyfin to obtain a token, persist encrypted password for auto-renew.
        do {
          let auth = try await JellyfinService.login(
            baseURL: url, username: username, password: password, httpClient: self.httpClient)
          let tmpSvc = JellyfinService(
            baseURL: url, apiKey: auth.token, userId: auth.userId, httpClient: self.httpClient)
          let info = try? await tmpSvc.getServerInfo()

          self.config.jellyfinUrl = url
          self.config.jellyfinApiKey = auth.token
          self.config.jellyfinUserId = auth.userId

          try await store.set("jellyfin_url", url)
          try await store.set("jellyfin_api_key", auth.token)
          try await store.set("jellyfin_user_id", auth.userId)
          try await store.set("jellyfin_username", username)
          let key = try SecretsManager.loadOrCreateKey(logger: self.logger)
          let enc = try SecretsManager.encryptString(password, key: key)
          try await store.set("jellyfin_password_enc", enc)

          self.movieService.reconfigureJellyfin(
            baseURL: url, apiKey: auth.token, userId: auth.userId)

          return try jsonResponse(
            JellyfinSaveResponse(
              success: true, error: nil, userId: auth.userId, serverName: info?.serverName,
              version: info?.version, localAddress: info?.localAddress))
        } catch {
          return try jsonResponse(
            JellyfinSaveResponse(
              success: false, error: error.localizedDescription, userId: nil, serverName: nil,
              version: nil, localAddress: nil))
        }
      }

      // Manual-token path — trust what the caller gave us.
      if let v = payload.jellyfin_url { self.config.jellyfinUrl = v }
      if let v = payload.jellyfin_api_key { self.config.jellyfinApiKey = v }
      if let v = payload.jellyfin_user_id { self.config.jellyfinUserId = v }
      try await store.set("jellyfin_url", self.config.jellyfinUrl)
      try await store.set("jellyfin_api_key", self.config.jellyfinApiKey)
      try await store.set("jellyfin_user_id", self.config.jellyfinUserId)
      self.movieService.reconfigureJellyfin(
        baseURL: self.config.jellyfinUrl, apiKey: self.config.jellyfinApiKey,
        userId: self.config.jellyfinUserId)
      return try jsonResponse(
        JellyfinSaveResponse(
          success: true, error: nil, userId: self.config.jellyfinUserId, serverName: nil,
          version: nil, localAddress: nil))
    }

    struct SettingsInfo: Codable {
      let jellyfin_url: String
      let jellyfin_api_key_set: Bool
      let jellyfin_user_id: String
      let jellyfin_username: String
      let anthropic_key_set: Bool
      let omdb_key_set: Bool
      let enable_auto_tagging: Bool
    }
    settings.get("info") { request, context in
      let store = SettingsStore(db: self.movieService.fluent.db(), logger: self.logger)
      try await store.ensureTable()
      let url = try await store.get("jellyfin_url") ?? self.config.jellyfinUrl
      let uid = try await store.get("jellyfin_user_id") ?? self.config.jellyfinUserId
      let api = (try await store.get("jellyfin_api_key")) ?? self.config.jellyfinApiKey
      let user = (try await store.get("jellyfin_username")) ?? ""
      let anth = (try await store.get("anthropic_api_key")) ?? (self.config.anthropicApiKey ?? "")
      let omdb = (try await store.get("omdb_api_key")) ?? (self.config.omdbApiKey ?? "")
      let info = SettingsInfo(
        jellyfin_url: url,
        jellyfin_api_key_set: !api.isEmpty,
        jellyfin_user_id: uid,
        jellyfin_username: user,
        anthropic_key_set: !anth.isEmpty,
        omdb_key_set: !omdb.isEmpty,
        enable_auto_tagging: self.config.enableAutoTagging
      )
      return try jsonResponse(info)
    }

  }

  // MARK: - Onboarding status (first-run detection)

  private func addOnboardingRoutes(to router: RouterGroup<BasicRequestContext>) {
    let onboarding = router.group("onboarding")
    struct OnboardingStatusResponse: Codable {
      let configured: Bool
      let has_jellyfin: Bool
      let has_anthropic_key: Bool
      let has_omdb_key: Bool
    }
    onboarding.get("status") { request, context in
      let store = SettingsStore(db: self.movieService.fluent.db(), logger: self.logger)
      try await store.ensureTable()
      let url = (try await store.get("jellyfin_url")) ?? self.config.jellyfinUrl
      let api = (try await store.get("jellyfin_api_key")) ?? self.config.jellyfinApiKey
      let uid = (try await store.get("jellyfin_user_id")) ?? self.config.jellyfinUserId
      let anth = (try await store.get("anthropic_api_key")) ?? (self.config.anthropicApiKey ?? "")
      let omdb = (try await store.get("omdb_api_key")) ?? (self.config.omdbApiKey ?? "")
      let hasJellyfin = !url.isEmpty && !api.isEmpty && !uid.isEmpty
      return try jsonResponse(OnboardingStatusResponse(
        configured: hasJellyfin,
        has_jellyfin: hasJellyfin,
        has_anthropic_key: !anth.isEmpty,
        has_omdb_key: !omdb.isEmpty
      ))
    }
  }
}

// MARK: - Response Types

struct SyncStatusResponse: Codable, Sendable {
  let isRunning: Bool
  let lastSyncAt: Date?
  let lastSyncDuration: TimeInterval?
  let moviesFound: Int
  let moviesUpdated: Int
  let moviesDeleted: Int
  let errors: [String]
}

struct ConnectionTestResponse: Codable, Sendable {
  let success: Bool
  let serverInfo: JellyfinServerInfo?
  let error: String?
}

struct ErrorResponse: Codable, Sendable {
  let error: String
  let message: String
  let status: Int
}
