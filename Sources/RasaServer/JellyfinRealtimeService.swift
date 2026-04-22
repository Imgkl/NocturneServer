import Foundation
import Logging
import WebSocketKit
import NIOCore
import NIOHTTP1

/// Background service that listens to Jellyfin WebSocket `/socket` for real-time library changes
/// and applies them to the local database by upserting new/updated items and deleting removed ones.
final class JellyfinRealtimeService: @unchecked Sendable {
    private let config: RasaConfiguration
    private let movieService: MovieService
    private let suggestionService: SuggestionService
    private let eventLoopGroup: EventLoopGroup
    private let logger: Logger

    private var socket: WebSocket?
    private var running = false

    // No additional debounce; Jellyfin already batches LibraryChanged

    init(
        config: RasaConfiguration,
        movieService: MovieService,
        suggestionService: SuggestionService,
        eventLoopGroup: EventLoopGroup,
        logger: Logger
    ) {
        self.config = config
        self.movieService = movieService
        self.suggestionService = suggestionService
        self.eventLoopGroup = eventLoopGroup
        self.logger = Logger(label: "JellyfinRealtime")
    }

    func start() {
        guard !running else { return }
        running = true
        Task { await self.runLoop() }
    }

    func stop() async {
        running = false
        do { try await socket?.close() } catch { }
        socket = nil
    }

    private func buildSocketURL() -> (scheme: String, host: String, port: Int, pathWithQuery: String)? {
        let base = config.jellyfinUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base) else { return nil }
        guard let scheme = url.scheme, let host = url.host else { return nil }
        let isSecure = (scheme.lowercased() == "https")
        let wsScheme = isSecure ? "wss" : "ws"
        let port = url.port ?? (isSecure ? 443 : 80)
        // Build /socket path with query
        var comps = URLComponents()
        comps.path = "/socket"
        var q: [URLQueryItem] = [
            URLQueryItem(name: "api_key", value: config.jellyfinApiKey),
            URLQueryItem(name: "deviceId", value: "RasaServer-\(UUID().uuidString)"),
            URLQueryItem(name: "format", value: "json")
        ]
        // Some servers expect UserId as well; include if available
        if !config.jellyfinUserId.isEmpty { q.append(URLQueryItem(name: "UserId", value: config.jellyfinUserId)) }
        comps.queryItems = q
        let pathWithQuery = (comps.string ?? "/socket")
        return (wsScheme, host, port, pathWithQuery)
    }

    private func authHeader() -> HTTPHeaders {
        var headers = HTTPHeaders()
        let deviceId = "RasaServer-\(UUID().uuidString)"
        let auth = "MediaBrowser Client=\"Rasa\", Device=\"RasaServer\", DeviceId=\"\(deviceId)\", Version=\"1.0.0\""
        headers.add(name: "X-Emby-Authorization", value: auth)
        return headers
    }

    private func runLoop() async {
        var backoff: TimeInterval = 1
        let maxBackoff: TimeInterval = 60
        while running {
            do {
                guard let (scheme, host, port, path) = buildSocketURL() else {
                    logger.warning("Realtime: Jellyfin URL not configured; retrying later")
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    continue
                }
                logger.info("Realtime: connecting to \(scheme)://\(host):\(port)\(path)")
                let urlStr = "\(scheme)://\(host):\(port)\(path)"
                let closePromise = eventLoopGroup.next().makePromise(of: Void.self)
                try await WebSocket.connect(to: urlStr, headers: authHeader(), on: eventLoopGroup) { [weak self] (ws: WebSocket) in
                    guard let self = self else { return }
                    self.socket = ws
                    ws.onText { [weak self] (_: WebSocket, text: String) in
                        Task { await self?.handleText(text) }
                    }
                    // Enable built-in automatic pings (keepalive)
                    ws.pingInterval = .seconds(30)
                    self.sendSessionsStart(ws: ws)
                    ws.onClose.whenComplete { _ in
                        closePromise.succeed(())
                    }
                }.get()
                // Reset backoff only after successful connect
                backoff = 1

                // Wait for close
                try await closePromise.futureResult.get()
                logger.warning("Realtime: socket closed")
                self.socket = nil
            } catch {
                logger.error("Realtime: connection error: \(String(describing: error))")
            }
            // Reconnect with backoff
            if running {
                let delay = UInt64(backoff * 1_000_000_000)
                logger.info("Realtime: reconnecting in \(Int(backoff))s")
                try? await Task.sleep(nanoseconds: delay)
                backoff = min(maxBackoff, backoff * 2)
            }
        }
    }

    // Using ws.pingInterval for keepalive; no manual ping loop needed

    private func sendSessionsStart(ws: WebSocket) {
        // Ask server to start sending session messages; harmless if ignored
        let payload = "{\"MessageType\":\"SessionsStart\"}"
        ws.send(payload)
    }

    private func handleText(_ text: String) async {
        guard let data = text.data(using: .utf8) else { return }
        do {
            let any = try JSONSerialization.jsonObject(with: data, options: [])
            guard let dict = any as? [String: Any] else { return }
            guard let type = dict["MessageType"] as? String else { return }

            switch type {
            case "LibraryChanged":
                guard let dataObj = dict["Data"] as? [String: Any] else { return }
                let added = (dataObj["ItemsAdded"] as? [String]) ?? []
                let updated = (dataObj["ItemsUpdated"] as? [String]) ?? []
                let removed = (dataObj["ItemsRemoved"] as? [String]) ?? []
                let addUpdSet = Set(added + updated)
                let removedSet = Set(removed)
                let finalAddUpd = Array(addUpdSet.subtracting(removedSet))
                Task { [weak self] in
                    await self?.processChanges(addUpd: finalAddUpd, removed: Array(removedSet))
                }
            default:
                // Ignore other message types
                break
            }
        } catch {
            logger.debug("Realtime: failed to parse message: \(text.prefix(200)) ... error=\(error)")
        }
    }

    private func processChanges(addUpd: [String], removed: [String]) async {
        if addUpd.isEmpty && removed.isEmpty { return }
        logger.info("Realtime: processing changes added/updated=\(addUpd.count) removed=\(removed.count)")

        // 1) Process removals first — drops the jellyfin_id FK stub and cascades movie_tags.
        for id in removed {
            do {
                let ok = try await movieService.deleteMovieByJellyfinId(id)
                if ok { logger.info("Realtime: deleted \(id)") }
            } catch {
                logger.error("Realtime: delete failed for \(id): \(error)")
            }
        }

        // 2) Upsert stubs for new/updated items (ID + last_seen_at only),
        //    then enqueue a Claude suggestion if auto-tagging is on.
        for id in addUpd {
            do {
                _ = try await movieService.upsertJellyfinId(id)
                if config.enableAutoTagging {
                    suggestionService.enqueueInBackground(jellyfinId: id)
                }
            } catch {
                logger.error("Realtime: upsert failed for \(id): \(error)")
            }
        }
    }
}
