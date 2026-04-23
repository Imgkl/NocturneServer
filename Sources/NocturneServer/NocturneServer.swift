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
        
        let llmService = LLMService(httpClient: httpClient)
        
        let movieService = MovieService(
            config: appConfig,
            fluent: fluent,
            jellyfinService: jellyfinService,
            llmService: llmService
        )
        let suggestionService = SuggestionService(
            fluent: fluent,
            jellyfinService: jellyfinService,
            llmService: llmService,
            config: appConfig
        )
        // Break the cycle: both services hold weak refs to each other.
        movieService.suggestionService = suggestionService
        suggestionService.movieServiceRef = movieService

        // Start realtime listener if configured
        var realtime: JellyfinRealtimeService? = nil
        if !appConfig.jellyfinUrl.isEmpty && !appConfig.jellyfinApiKey.isEmpty && !appConfig.jellyfinUserId.isEmpty {
            let rt = JellyfinRealtimeService(
                config: appConfig,
                movieService: movieService,
                suggestionService: suggestionService,
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
            suggestionService: suggestionService,
            fluent: fluent,
            logger: logger,
            isFirstRun: false,
            httpClient: httpClient,
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

func runMigrations(fluent: Fluent, logger: Logger) async throws {
    await fluent.migrations.add(CreateMovies())
    await fluent.migrations.add(CreateTags())
    await fluent.migrations.add(CreateMovieTags())
    await fluent.migrations.add(SeedMoodTags())
    await fluent.migrations.add(CreateTagSuggestions())
    await fluent.migrations.add(UpdateRegionalGemsDescription())

    logger.info("🔄 Running database migrations...")
    try await fluent.migrate()
    logger.info("✅ Database migrations completed")
}

// MARK: - Application Setup

func createApplication(
    config: NocturneConfiguration,
    movieService: MovieService,
    suggestionService: SuggestionService,
    fluent: Fluent,
    logger: Logger,
    isFirstRun: Bool,
    httpClient: HTTPClient,
    eventLoopGroup: EventLoopGroup
) async throws -> Application<RouterResponder<BasicRequestContext>> {

    let router = Router()

    // Add middleware
    router.middlewares.add(LoggingMiddleware())
    router.middlewares.add(CORSMiddleware())
    router.middlewares.add(JSONErrorMiddleware())

    let apiRoutes = APIRoutes(
        movieService: movieService,
        suggestionService: suggestionService,
        config: config,
        httpClient: httpClient
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
            let payload = ErrorResponse(error: "HTTP Error", message: http.localizedDescription, status: Int(http.status.code))
            return try jsonResponse(payload, status: http.status)
        } catch let llm as LLMError {
            // Map LLM errors to appropriate HTTP status for the client
            if case .httpError(let code, _) = llm {
                let status: HTTPResponse.Status
                switch code {
                case 401: status = .unauthorized
                case 403: status = .forbidden
                case 429: status = .tooManyRequests
                default: status = .badGateway
                }
                let payload = ErrorResponse(error: "LLM Error", message: llm.description, status: Int(status.code))
                return try jsonResponse(payload, status: status)
            }
            let payload = ErrorResponse(error: "LLM Error", message: llm.description, status: 502)
            return try jsonResponse(payload, status: .badGateway)
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
