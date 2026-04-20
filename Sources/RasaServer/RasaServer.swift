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
struct RasaServerApp {
    static func main() async throws {
        // Setup logging
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = .info
            return handler
        }

        let logger = Logger(label: "RasaServer")
        logger.info("🎞️ Starting Rasa Server v1.0.0")
        
        // Create shared EventLoopGroup for server and HTTP client
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        // Create HTTP client on shared group
        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(eventLoopGroup))
        
        // YAML removed: start with defaults, then hydrate from DB
        let appConfig = RasaConfiguration()
        
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

    logger.info("🔄 Running database migrations...")
    try await fluent.migrate()
    logger.info("✅ Database migrations completed")
}

// MARK: - Application Setup

func createApplication(
    config: RasaConfiguration,
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

    // Always register routes; gate behavior dynamically based on configuration
    setupWizardRoutes(router: router, config: config, movieService: movieService, httpClient: httpClient, fluent: fluent)
    let apiRoutes = APIRoutes(
        movieService: movieService,
        suggestionService: suggestionService,
        config: config,
        httpClient: httpClient
    )
    apiRoutes.addRoutes(to: router)
    
    // Root: serve SPA index (from public/) or redirect to /setup if not configured
    router.get("/") { _, _ in
        let dbExists = FileManager.default.fileExists(atPath: config.databasePath)
        let needsConfig = !dbExists || config.jellyfinApiKey.isEmpty || config.jellyfinUserId.isEmpty
        if needsConfig {
            return Response(status: .found, headers: HTTPFields([HTTPField(name: .location, value: "/setup")]))
        }
        // Serve built index.html
        if let htmlData = try? Data(contentsOf: URL(fileURLWithPath: "public/index.html")),
           let htmlString = String(data: htmlData, encoding: .utf8) {
            return textResponse(htmlString, contentType: "text/html; charset=utf-8")
        }
        return textResponse("<h1>Rasa</h1>")
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
            serverName: "Rasa/1.0.0"
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

// MARK: - Setup Wizard Routes

func setupWizardRoutes(
    router: Router<BasicRequestContext>,
    config: RasaConfiguration,
    movieService: MovieService,
    httpClient: HTTPClient,
    fluent: Fluent
) {
    let logger = Logger(label: "SetupWizard")
    router.get("/setup") { _, _ in getSetupWizard() }
    
    // Handle setup form submission (username/password login)
    router.post("/setup") { request, context in
        let setupData = try await request.decode(as: SetupRequest.self, context: context)
        
        // Login to Jellyfin using username/password to obtain token and userId
        let auth = try await JellyfinService.login(
            baseURL: setupData.jellyfinUrl,
            username: setupData.jellyfinUsername,
            password: setupData.jellyfinPassword,
            httpClient: httpClient
        )
        
        // Update configuration with resolved values
        config.jellyfinUrl = setupData.jellyfinUrl
        config.jellyfinApiKey = auth.token
        config.jellyfinUserId = auth.userId

        // Persist to DB settings store
        let store = SettingsStore(db: fluent.db(), logger: logger)
        try await store.ensureTable()
        try await store.set("jellyfin_url", config.jellyfinUrl)
        try await store.set("jellyfin_api_key", config.jellyfinApiKey)
        try await store.set("jellyfin_user_id", config.jellyfinUserId)
        // Hot‑reload runtime Jellyfin client so first sync works immediately after setup
        // Reconfigure: call via DB flag checked on first /sync; here we only persist
        
        // Respond with redirect to root
        return try jsonResponse(SetupResponse(
            success: true,
            message: "Configuration saved successfully! Redirecting...",
            redirectUrl: "/"
        ))
    }
    
    // Block API routes during setup
    router.get("/api") { _, _ in Response(status: .serviceUnavailable) }
}

// MARK: - Setup Data Models

struct SetupRequest: Codable {
    let jellyfinUrl: String
    let jellyfinUsername: String
    let jellyfinPassword: String
}

struct SetupResponse: Codable {
    let success: Bool
    let message: String
    let redirectUrl: String
}

// MARK: - Setup Wizard HTML

func getSetupWizard() -> Response {
    let html = """
    <!DOCTYPE html>
    <html lang=\"en\">
    <head>
        <meta charset=\"UTF-8\" />
        <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\" />
        <title>🎞️ Rasa Setup</title>
        <style>
            *{margin:0;padding:0;box-sizing:border-box}
            body{
                font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Inter,system-ui,sans-serif;
                min-height:100vh;display:flex;align-items:center;justify-content:center;padding:32px;
                background: radial-gradient(1200px 600px at 10% 10%, #c7d2fe55 0%, transparent 60%),
                            radial-gradient(1000px 500px at 90% 20%, #f0abfc55 0%, transparent 60%),
                            linear-gradient(135deg,#eef2ff 0%,#f5f3ff 100%);
            }
            .card{
                width:100%;max-width:560px;border-radius:28px;padding:28px 28px 24px;position:relative;
                background:rgba(255,255,255,0.75);backdrop-filter:saturate(140%) blur(10px);
                border:1px solid rgba(17,24,39,0.06);
                box-shadow:0 20px 50px -20px rgba(16,24,40,.35), 0 0 0 1px rgba(16,24,40,.04) inset;
            }
            .logo{display:flex;align-items:center;gap:10px;justify-content:center;margin-bottom:6px}
            .logo .badge{width:36px;height:36px;border-radius:12px;display:grid;place-items:center;
                background:linear-gradient(135deg,#6366f1,#a855f7);color:white;box-shadow:0 8px 20px -10px #7c3aed}
            h1{font-size:28px;letter-spacing:-.02em;text-align:center;
                background:linear-gradient(45deg,#4338ca,#a855f7);-webkit-background-clip:text;-webkit-text-fill-color:transparent}
            .sub{color:#6b7280;text-align:center;margin-top:4px;margin-bottom:18px}
            .chips{display:flex;gap:8px;justify-content:center;margin-bottom:14px}
            .chip{font-size:12px;padding:8px 12px;border-radius:9999px;border:1px solid rgba(17,24,39,.08);background:#fff}
            label{display:block;font-weight:600;color:#111827;margin:10px 0 6px 4px}
            input{width:100%;padding:14px 16px;border-radius:14px;border:1px solid rgba(17,24,39,.12);
                background:#fff;font-size:15px;outline:none;transition:box-shadow .2s,border-color .2s}
            input:focus{border-color:#6366f1;box-shadow:0 0 0 4px rgba(99,102,241,.15)}
            .hint{font-size:12px;color:#6b7280;margin-top:6px}
            .btn{width:100%;margin-top:18px;padding:14px 18px;border:none;border-radius:9999px;cursor:pointer;
                background:linear-gradient(90deg,#111827,#0b1220);color:#fff;font-weight:600;letter-spacing:.2px;
                box-shadow:0 18px 40px -18px rgba(16,24,40,.45)}
            .btn:disabled{opacity:.6;cursor:not-allowed}
            .alert{display:none;margin-top:12px;padding:12px 14px;border-radius:12px;font-size:14px}
            .error{background:#fee2e2;color:#991b1b;border:1px solid #fecaca}
            .success{background:#dcfce7;color:#166534;border:1px solid #bbf7d0}
        </style>
    </head>
    <body>
        <div class=\"card\">
            <div class=\"logo\"><h1>Rasa</h1></div>
            <div class=\"sub\">Configure your Jellyfin connection</div>
            <div id=\"error\" class=\"alert error\"></div>
            <div id=\"success\" class=\"alert success\"></div>
            <form id=\"setupForm\">
                <label for=\"jellyfinUrl\">Jellyfin Server URL</label>
                <input id=\"jellyfinUrl\" name=\"jellyfinUrl\" type=\"url\" placeholder=\"http://192.168.0.111:8097\" required />
                <div class=\"hint\">Your Jellyfin server address with port</div>
                <label for=\"jellyfinUsername\">Jellyfin Username</label>
                <input id=\"jellyfinUsername\" name=\"jellyfinUsername\" type=\"text\" placeholder=\"Your Jellyfin username\" required />
                <label for=\"jellyfinPassword\">Jellyfin Password</label>
                <input id=\"jellyfinPassword\" name=\"jellyfinPassword\" type=\"password\" placeholder=\"Your Jellyfin password\" required />
                <button id=\"submitBtn\" type=\"submit\" class=\"btn\">🚀 Configure & Start Rasa</button>
            </form>
        </div>
        <script>
            const form = document.getElementById('setupForm');
            const submitBtn = document.getElementById('submitBtn');
            const err = document.getElementById('error');
            const ok = document.getElementById('success');
            form.addEventListener('submit', async (e) => {
                e.preventDefault();
                submitBtn.disabled = true; submitBtn.textContent = '🔄 Testing connection...';
                err.style.display='none'; ok.style.display='none';
                const data = Object.fromEntries(new FormData(form));
                try {
                    const res = await fetch('/setup', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(data) });
                    const result = await res.json();
                    if(res.ok && result.success){
                        ok.textContent = result.message; ok.style.display='block';
                        submitBtn.textContent = '✅ Success! Redirecting...';
                        setTimeout(()=>{ window.location.href = result.redirectUrl; }, 1200);
                    } else {
                        throw new Error(result.message || 'Configuration failed');
                    }
                } catch (e) {
                    err.textContent = 'Error: ' + (e.message || e); err.style.display='block';
                    submitBtn.disabled = false; submitBtn.textContent = '🚀 Configure & Start Rasa';
                }
            });
        </script>
    </body>
    </html>
    """
    
    return textResponse(html, contentType: "text/html; charset=utf-8")
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
