import Foundation
import Logging
import Hummingbird
import AsyncHTTPClient
import NIOCore
import NIOPosix
import HTTPTypes
import FluentKit
import FluentSQLiteDriver
import HummingbirdFluent

@main
struct NocturneServerApp {
    static func main() async throws {
        // Setup logging
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = .info
            return handler
        }

        let logger = Logger(label: "NocturneServer")
        logger.info("🎞️ Starting Nocturne v1.0.0")
        
        // Create shared EventLoopGroup for server and HTTP client
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        // Create HTTP client on shared group
        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(eventLoopGroup))
        
        // YAML removed: start with defaults, then hydrate from DB
        let appConfig = NocturneConfiguration()
        
        // Setup database
        let fluent = try setupDatabase(path: appConfig.databasePath, logger: logger)
        // Ensure settings table exists (no migrations)
        do {
            let store = SettingsStore(db: fluent.db(), logger: logger)
            try await store.ensureTable()
            // Load settings from DB into config (overriding YAML)
            let all = try await store.loadAll()
            if let v = all["jellyfin_url"] { appConfig.jellyfinUrl = v }
            if let v = all["jellyfin_api_key"] { appConfig.jellyfinApiKey = v }
            if let v = all["jellyfin_user_id"] { appConfig.jellyfinUserId = v }
            if let v = all["anthropic_api_key"], !v.isEmpty { appConfig.anthropicApiKey = v }
            if let v = all["omdb_api_key"], !v.isEmpty { appConfig.omdbApiKey = v }
            if let v = all["enable_auto_tagging"] { appConfig.enableAutoTagging = (v == "true") }
        } catch {
            logger.error("Settings table init failed: \(error)")
        }
        
        // Auto-run migrations
        try await runMigrations(fluent: fluent, logger: logger)
        
        // Allow override via WEBUI_PORT env before app is created
        if let portEnv = ProcessInfo.processInfo.environment["WEBUI_PORT"], let p = Int(portEnv) {
            logger.info("🌐 Overriding port via WEBUI_PORT=\(p)")
            appConfig.port = p
        }
        // Create services (even if not configured yet)
        let jellyfinService = JellyfinService(
            baseURL: appConfig.jellyfinUrl,
            apiKey: appConfig.jellyfinApiKey,
            userId: appConfig.jellyfinUserId,
            httpClient: httpClient
        )
        
        let outbound = OutboundClient(
            transport: AsyncHTTPClientTransport(client: httpClient),
            fluent: fluent,
            logger: Logger(label: "Outbound")
        )
        let anthropic = AnthropicClient(outbound: outbound)

        // Enrichment: Wikidata + Wikipedia + awards into the per-film text block.
        let version = ProcessInfo.processInfo.environment["NOCTURNE_VERSION"] ?? "dev"
        let userAgent = "NocturneServer/\(version) (+https://github.com/Imgkl/NocturneServer)"
        let wikimediaLimiter = RateLimiter(perSecond: 2)
        let settingsStore = SettingsStore(db: fluent.db(), logger: logger)
        let omdbCache = OmdbCacheStore(db: fluent.db(), logger: logger)
        try await omdbCache.ensureTable()
        let awardsResolver = AwardsResolver(
            outbound: outbound, fluent: fluent, limiter: wikimediaLimiter, userAgent: userAgent,
            omdb: OmdbClient(outbound: outbound), omdbCache: omdbCache, settings: settingsStore)
        let synopsisService = FallbackSynopsisService(anthropic: anthropic, settings: settingsStore)
        let enrichmentService = EnrichmentService(
            fluent: fluent,
            jellyfin: jellyfinService,
            resolver: WikidataResolver(outbound: outbound, limiter: wikimediaLimiter, userAgent: userAgent),
            wikipedia: WikipediaClient(outbound: outbound, limiter: wikimediaLimiter, userAgent: userAgent),
            awards: awardsResolver,
            synopsis: synopsisService,
            apiKey: { [settingsStore, appConfig] in
                if let stored = try await settingsStore.get(TaggerPipeline.apiKeySetting), !stored.isEmpty { return stored }
                return appConfig.anthropicApiKey
            })
        let runService = RunService(fluent: fluent)
        let staleRuns = try await runService.markStaleOnBoot()
        if staleRuns > 0 { logger.warning("Marked \(staleRuns) stale run(s) from a previous process as error") }
        let coverageJob = EnrichCoverageJob(runService: runService, enrichment: enrichmentService, fluent: fluent)
        let enrichmentRoutes = EnrichmentRoutes(enrichment: enrichmentService, coverage: coverageJob, runService: runService)
        
        let movieService = MovieService(
            config: appConfig,
            fluent: fluent,
            jellyfinService: jellyfinService
        )

        // Tagger: reader + policy + decision records; review queue; backfill on runs.
        let readerService = ReaderService(
            anthropic: anthropic, settings: settingsStore, buckets: appConfig.moodBuckets,
            rules: appConfig.autoTaggingPrompt, maxTags: appConfig.maxAutoTags)
        let budget = BudgetGuard(fluent: fluent, settings: settingsStore)
        // The classifier of record (TypeSafe Jev). Whether it runs is the `classifier.provider` setting.
        var jevClient = JevClient(outbound: outbound, buckets: appConfig.moodBuckets)
        if let base = ProcessInfo.processInfo.environment["TYPESAFE_BASE"], !base.isEmpty { jevClient.baseURL = base }
        if let model = try? await settingsStore.get(JevClient.modelSetting), !model.isEmpty { jevClient.model = model }
        let pipeline = TaggerPipeline(
            fluent: fluent, config: appConfig, enrichment: enrichmentService, reader: readerService, classifier: jevClient,
            movies: movieService, budget: budget, settings: settingsStore,
            titles: { [jellyfinService] in
                var titles: [String: String] = [:]
                if let items = try? await jellyfinService.fetchAllMovies() {
                    for item in items { if let id = item.id, let name = item.name { titles[id] = name } }
                }
                return titles
            })
        movieService.tagger = pipeline
        let reviewQueue = ReviewQueue(fluent: fluent, config: appConfig, movies: movieService, pipeline: pipeline)
        let backfillJob = BackfillJob(runService: runService, pipeline: pipeline, queue: reviewQueue, fluent: fluent, config: appConfig)
        let verifyService = VerifyService(fluent: fluent, config: appConfig, movies: movieService)
        let taggerRoutes = TaggerRoutes(movies: movieService, pipeline: pipeline, queue: reviewQueue, backfill: backfillJob, verify: verifyService)
        let modelSettingsRoutes = ModelSettingsRoutes(settings: settingsStore, budget: budget, coverage: coverageJob, config: appConfig, classifier: jevClient)
        let evalService = EvalService(fluent: fluent, config: appConfig, settings: settingsStore, runService: runService)
        let evalRoutes = EvalRoutes(eval: evalService)
        let teachService = TeachService(fluent: fluent, config: appConfig, settings: settingsStore, anthropic: anthropic, backfill: backfillJob)
        let teachRoutes = TeachRoutes(teach: teachService, settings: settingsStore, config: appConfig)
        let guideRoutes = GuideRoutes(teach: teachService, settings: settingsStore, config: appConfig)

        // One-time seed: the legacy ANTHROPIC_MODEL env var becomes the initial reader model setting.
        if let envModel = ProcessInfo.processInfo.environment["ANTHROPIC_MODEL"], !envModel.isEmpty,
           (try await settingsStore.get(ReaderService.modelSetting) ?? "").isEmpty {
            try await settingsStore.set(ReaderService.modelSetting, envModel)
            logger.warning("ANTHROPIC_MODEL is deprecated; seeded models.reader = \(envModel). Change it in Settings from now on.")
        }

        // Start realtime listener if configured
        var realtime: JellyfinRealtimeService? = nil
        if !appConfig.jellyfinUrl.isEmpty && !appConfig.jellyfinApiKey.isEmpty && !appConfig.jellyfinUserId.isEmpty {
            let rt = JellyfinRealtimeService(
                config: appConfig,
                movieService: movieService,
                pipeline: pipeline,
                eventLoopGroup: eventLoopGroup,
                logger: logger
            )
            rt.start()
            realtime = rt
            logger.info("🔔 Jellyfin realtime listener started")
        } else {
            logger.warning("🔕 Realtime listener not started (missing Jellyfin url/token/userId). Complete setup at /setup")
        }

        // Create and run server
        let app = try await createApplication(
            config: appConfig,
            movieService: movieService,
            fluent: fluent,
            logger: logger,
            isFirstRun: false,
            httpClient: httpClient,
            outbound: outbound,
            enrichmentRoutes: enrichmentRoutes,
            taggerRoutes: taggerRoutes,
            modelSettingsRoutes: modelSettingsRoutes,
            evalRoutes: evalRoutes,
            teachRoutes: teachRoutes,
            guideRoutes: guideRoutes,
            eventLoopGroup: eventLoopGroup
        )

        logger.info("🚀 Server starting on \(appConfig.host):\(appConfig.port)")
        logger.info("🌐 Admin at http://\(appConfig.host):\(appConfig.port)")
        
        do {
            try await app.runService()
        } catch {
            logger.error("Server runService error: \(error)")
        }
        // Stop realtime first
        if let rt = realtime { await rt.stop() }
        // Shutdown in order: HTTP client, then event loop group (async)
        try await httpClient.shutdown()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            eventLoopGroup.shutdownGracefully { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }
}

// MARK: - Database Setup

func setupDatabase(path: String, logger: Logger) throws -> Fluent {
    let fluent = Fluent(logger: logger)

    let parent = (path as NSString).deletingLastPathComponent
    if !parent.isEmpty {
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
    }

    fluent.databases.use(.sqlite(.file(path)), as: .sqlite)

    logger.info("📊 Database configured at: \(path)")
    return fluent
}

/// Migrations that shipped before the tagger rewrite, in order.
let legacyMigrations: [any AsyncMigration] = [
    CreateMovies(),
    CreateTags(),
    CreateMovieTags(),
    SeedMoodTags(),
    CreateTagSuggestions(),
    UpdateRegionalGemsDescription(),
    AddKindToTagSuggestions(),
]

/// Tagger rewrite, phase 1 (see docs/superpowers/specs/2026-10-21-tagger-rewrite-design.md).
let taggerV2Migrations: [any AsyncMigration] = [
    CreateTaggerV2Tables(),
    AddLabelSourceToMovieTags(),
    AddResolvedByToTagSuggestions(),
    AddCurrentDecisionToMovies(),
    SeedMissingMoodTags(),
    AddPlayedToMovies(),
    AddLeadTextToEnrichment(),
    CreateTeachAnswers(),
]

func runMigrations(fluent: Fluent, logger: Logger) async throws {
    for migration in legacyMigrations + taggerV2Migrations {
        await fluent.migrations.add(migration)
    }

    logger.info("🔄 Running database migrations...")
    try await fluent.migrate()
    logger.info("✅ Database migrations completed")
}

// MARK: - Application Setup

func createApplication(
    config: NocturneConfiguration,
    movieService: MovieService,
    fluent: Fluent,
    logger: Logger,
    isFirstRun: Bool,
    httpClient: HTTPClient,
    outbound: OutboundClient,
    enrichmentRoutes: EnrichmentRoutes,
    taggerRoutes: TaggerRoutes,
    modelSettingsRoutes: ModelSettingsRoutes,
    evalRoutes: EvalRoutes,
    teachRoutes: TeachRoutes,
    guideRoutes: GuideRoutes,
    eventLoopGroup: EventLoopGroup
) async throws -> Application<RouterResponder<BasicRequestContext>> {

    let router = Router()

    // Add middleware
    router.middlewares.add(LoggingMiddleware())
    router.middlewares.add(CORSMiddleware())
    router.middlewares.add(JSONErrorMiddleware())

    let apiRoutes = APIRoutes(
        movieService: movieService,
        config: config,
        httpClient: httpClient,
        outbound: outbound,
        enrichmentRoutes: enrichmentRoutes,
        taggerRoutes: taggerRoutes,
        modelSettingsRoutes: modelSettingsRoutes,
        evalRoutes: evalRoutes,
        teachRoutes: teachRoutes,
        guideRoutes: guideRoutes
    )
    apiRoutes.addRoutes(to: router)

    // Root: always serve the SPA. The React app calls /api/v1/onboarding/status
    // on mount and renders the OnboardingView if Jellyfin isn't configured.
    router.get("/") { _, _ in
        if let htmlData = try? Data(contentsOf: URL(fileURLWithPath: "public/index.html")),
           let htmlString = String(data: htmlData, encoding: .utf8) {
            return textResponse(htmlString, contentType: "text/html; charset=utf-8")
        }
        return textResponse("<h1>Nocturne</h1>")
    }
    // Serve assets under /assets/* by mapping the raw request path to the public folder
    let assets = router.group("assets")
    assets.get(":path*") { request, _ in
        let reqPath = request.uri.path // e.g. "/assets/index-XYZ.js"
        let full = "public" + reqPath
        return try staticFileResponse(path: full)
    }
    // Fallback: serve top-level files (e.g., /vite.svg) and SPA index.html
    router.get(":path*") { request, _ in
        let reqPath = request.uri.path
        let full = reqPath == "/" ? "public/index.html" : "public" + reqPath
        return try staticFileResponse(path: full)
    }
    
    // Create application AFTER routes are registered
    let app = Application(
        router: router,
        configuration: .init(
            address: .hostname(config.host, port: config.port),
            serverName: "Nocturne/1.0.0"
        ),
        services: [fluent],
        eventLoopGroupProvider: .shared(eventLoopGroup)
    )
    
    return app
}

// Serve static file from disk with basic content-type, default to index.html when directory
func staticFileResponse(path: String) throws -> Response {
    let url = URL(fileURLWithPath: path)
    var isDir: ObjCBool = false
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { throw HTTPError(.notFound) }
    let fileURL = isDir.boolValue ? url.appendingPathComponent("index.html") : url
    guard fm.fileExists(atPath: fileURL.path) else { throw HTTPError(.notFound) }
    let data = try Data(contentsOf: fileURL)
    let ext = fileURL.pathExtension.lowercased()
    let mime: String = {
        switch ext {
        case "js": return "application/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "html": return "text/html; charset=utf-8"
        default: return "application/octet-stream"
        }
    }()
    var buf = ByteBufferAllocator().buffer(capacity: data.count)
    buf.writeBytes(data)
    let headers = HTTPFields([HTTPField(name: .contentType, value: mime)])
    return Response(status: .ok, headers: headers, body: .init(byteBuffer: buf))
}

// MARK: - Middleware

struct LoggingMiddleware: MiddlewareProtocol {
    typealias Input = Request
    typealias Output = Response
    typealias Context = BasicRequestContext
    
    func handle(_ request: Request, context: Context, next: (Input, Context) async throws -> Output) async throws -> Output {
        let start = DispatchTime.now()
        let response = try await next(request, context)
        let end = DispatchTime.now()
        
        let duration = Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
        
        let logger = Logger(label: "HTTP")
        logger.info("\(request.method) \(request.uri.path) → \(response.status.code) (\(String(format: "%.2f", duration))ms)")
        
        return response
    }
}

struct CORSMiddleware: MiddlewareProtocol {
    typealias Input = Request
    typealias Output = Response
    typealias Context = BasicRequestContext
    
    func handle(_ request: Request, context: Context, next: (Input, Context) async throws -> Output) async throws -> Output {
        if request.method == .options {
            let headers = HTTPFields([
                HTTPField(name: HTTPField.Name("Access-Control-Allow-Origin")!, value: "*"),
                HTTPField(name: HTTPField.Name("Access-Control-Allow-Methods")!, value: "GET, POST, PUT, DELETE, OPTIONS"),
                HTTPField(name: HTTPField.Name("Access-Control-Allow-Headers")!, value: "Content-Type, Authorization"),
                HTTPField(name: HTTPField.Name("Access-Control-Max-Age")!, value: "86400")
            ])
            return Response(status: .ok, headers: headers)
        }
        
        var response = try await next(request, context)
        var headers = response.headers
        headers[HTTPField.Name("Access-Control-Allow-Origin")!] = "*"
        headers[HTTPField.Name("Access-Control-Allow-Methods")!] = "GET, POST, PUT, DELETE, OPTIONS"
        headers[HTTPField.Name("Access-Control-Allow-Headers")!] = "Content-Type, Authorization"
        response.headers = headers
        return response
    }
}

struct JSONErrorMiddleware: MiddlewareProtocol {
    typealias Input = Request
    typealias Output = Response
    typealias Context = BasicRequestContext
    
    func handle(_ request: Request, context: Context, next: (Input, Context) async throws -> Output) async throws -> Output {
        do {
            return try await next(request, context)
        } catch let http as HTTPError {
            // `HTTPError(.badRequest, message:)` carries the route's message in `body`; without this the
            // client only sees the generic "operation couldn't be completed" text.
            let payload = ErrorResponse(error: "HTTP Error", message: http.body ?? http.localizedDescription, status: Int(http.status.code))
            return try jsonResponse(payload, status: http.status)
        } catch let outbound as OutboundError {
            let status: HTTPResponse.Status
            switch outbound {
            case .authFailure(_, let code): status = code == 403 ? .forbidden : .unauthorized
            case .exhausted: status = .tooManyRequests
            case .transport, .http: status = .badGateway
            }
            let payload = ErrorResponse(error: "Provider Error", message: outbound.description, status: Int(status.code))
            return try jsonResponse(payload, status: status)
        } catch let reader as ReaderError {
            let payload = ErrorResponse(error: "Reader Error", message: reader.description, status: 502)
            return try jsonResponse(payload, status: .badGateway)
        } catch let tagger as TaggerError {
            let status: HTTPResponse.Status
            switch tagger {
            case .missingAnthropicKey: status = .badRequest
            case .notFound, .movieNotFound, .noReaderAnswer: status = .notFound
            case .alreadyResolved: status = .conflict
            }
            let payload = ErrorResponse(error: "Tagger Error", message: tagger.description, status: Int(status.code))
            return try jsonResponse(payload, status: status)
        } catch let run as RunError {
            let status: HTTPResponse.Status = { if case .busy = run { return .conflict } else { return .notFound } }()
            let payload = ErrorResponse(error: "Run Error", message: run.description, status: Int(status.code))
            return try jsonResponse(payload, status: status)
        } catch let svc as MovieServiceError {
            // Treat missing/unsupported provider/api key as 400 Bad Request
            let payload = ErrorResponse(error: "Bad Request", message: svc.description, status: 400)
            return try jsonResponse(payload, status: .badRequest)
        } catch {
            let payload = ErrorResponse(error: "Internal Server Error", message: error.localizedDescription, status: 500)
            return try jsonResponse(payload, status: .internalServerError)
        }
    }
}
