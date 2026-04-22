import Foundation
import Logging
import AsyncHTTPClient
import NIOCore
import NIOHTTP1

final class JellyfinService: Sendable {
    let httpClient: HTTPClient
    private let userId: String
    let baseURL: String
    let apiKey: String
    private let deviceId: String
    private let logger = Logger(label: "JellyfinService")

    init(baseURL: String, apiKey: String, userId: String, httpClient: HTTPClient) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.apiKey = apiKey
        self.userId = userId
        self.httpClient = httpClient
        self.deviceId = "Nocturne-\(UUID().uuidString)"
    }

    // MARK: - Authentication (Username/Password)

    static func login(baseURL: String, username: String, password: String, httpClient: HTTPClient) async throws -> (token: String, userId: String) {
        let cleanBaseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let deviceId = "Nocturne-\(UUID().uuidString)"

        let loginData = [
            "Username": username,
            "Pw": password
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: loginData)

        var request = HTTPClientRequest(url: "\(cleanBaseURL)/Users/AuthenticateByName")
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        request.headers.add(name: "Authorization", value: "MediaBrowser Client=\"Nocturne\", Device=\"Nocturne\", DeviceId=\"\(deviceId)\", Version=\"1.0.0\"")
        request.body = .bytes(ByteBuffer(data: jsonData))

        let response = try await httpClient.execute(request, timeout: .seconds(30))

        guard response.status == .ok else {
            throw JellyfinError.authenticationFailed("Login failed with status: \(response.status)")
        }

        let responseData = try await response.body.collect(upTo: 1024 * 1024)
        let authResult = try JSONDecoder().decode(AuthenticationResult.self, from: responseData)

        return (token: authResult.accessToken ?? "", userId: authResult.user?.id ?? "")
    }

    // MARK: - Library Reconciliation

    /// Fetch the full movie catalog as a list of Jellyfin IDs only.
    /// Nocturne doesn't mirror Jellyfin metadata anymore — it only needs IDs to
    /// maintain tag associations.
    func fetchAllMovieIds() async throws -> [String] {
        logger.info("Fetching movie IDs from Jellyfin")

        let queryItems = [
            "Recursive": "true",
            "SortOrder": "Ascending",
            "Fields": "",
            "IncludeItemTypes": "Movie",
            "SortBy": "SortName"
        ]

        let queryString = queryItems.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }.joined(separator: "&")

        var request = HTTPClientRequest(url: "\(baseURL)/Users/\(userId)/Items?\(queryString)")
        request.method = .GET
        request.headers.add(name: "Authorization", value: "MediaBrowser Token=\"\(apiKey)\"")

        let response = try await httpClient.execute(request, timeout: .seconds(60))

        guard response.status == .ok else {
            throw JellyfinError.httpError(Int(response.status.code), "Failed to fetch movies: \(response.status)")
        }

        let responseData = try await response.body.collect(upTo: 10 * 1024 * 1024)
        let itemsResponse = try JSONDecoder().decode(JellyfinItemsResponse.self, from: responseData)
        let items = itemsResponse.items ?? []

        logger.info("Fetched \(items.count) movies from Jellyfin")
        return items.compactMap { $0.id }
    }

    /// Fetch the full BaseItemDto payload for one movie (used for admin proxy + LLM context building).
    func fetchMovie(id: String) async throws -> BaseItemDto {
        var request = HTTPClientRequest(url: "\(baseURL)/Users/\(userId)/Items/\(id)?Fields=Overview,Genres,People")
        request.method = .GET
        request.headers.add(name: "Authorization", value: "MediaBrowser Token=\"\(apiKey)\"")

        let response = try await httpClient.execute(request, timeout: .seconds(30))

        guard response.status == .ok else {
            throw JellyfinError.requestFailed("Failed to fetch movie: \(response.status)")
        }

        let responseData = try await response.body.collect(upTo: 1024 * 1024)
        return try JSONDecoder().decode(BaseItemDto.self, from: responseData)
    }

    /// Bulk fetch for the admin movies proxy — returns full BaseItemDto records.
    func fetchAllMovies() async throws -> [BaseItemDto] {
        logger.info("Fetching full movie catalog from Jellyfin (admin proxy)")

        let queryItems = [
            "Recursive": "true",
            "SortOrder": "Ascending",
            "Fields": "Overview,Genres,ProviderIds",
            "IncludeItemTypes": "Movie",
            "SortBy": "SortName"
        ]

        let queryString = queryItems.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }.joined(separator: "&")

        var request = HTTPClientRequest(url: "\(baseURL)/Users/\(userId)/Items?\(queryString)")
        request.method = .GET
        request.headers.add(name: "Authorization", value: "MediaBrowser Token=\"\(apiKey)\"")

        let response = try await httpClient.execute(request, timeout: .seconds(60))

        guard response.status == .ok else {
            throw JellyfinError.httpError(Int(response.status.code), "Failed to fetch movies: \(response.status)")
        }

        let responseData = try await response.body.collect(upTo: 10 * 1024 * 1024)
        let itemsResponse = try JSONDecoder().decode(JellyfinItemsResponse.self, from: responseData)
        return itemsResponse.items ?? []
    }

    // MARK: - Images (admin proxy uses this for posters)

    /// Fetch raw primary-image bytes for an item. Used by the poster cache / proxy.
    /// - Parameters:
    ///   - itemId: Jellyfin item ID
    ///   - fillWidth: Optional `fillWidth` param for server-side resizing. Nil = original.
    /// - Returns: Image bytes + the upstream Content-Type header.
    func fetchPosterBytes(itemId: String, fillWidth: Int?) async throws -> (data: Data, contentType: String) {
        var url = "\(baseURL)/Items/\(itemId)/Images/Primary"
        if let w = fillWidth {
            url += "?fillWidth=\(w)&quality=85"
        }
        var request = HTTPClientRequest(url: url)
        request.method = .GET
        request.headers.add(name: "Authorization", value: "MediaBrowser Token=\"\(apiKey)\"")
        let response = try await httpClient.execute(request, timeout: .seconds(30))
        guard response.status == .ok else {
            throw JellyfinError.httpError(Int(response.status.code), "Poster fetch failed: \(response.status)")
        }
        let contentType = response.headers.first(name: "Content-Type") ?? "image/jpeg"
        let buffer = try await response.body.collect(upTo: 10 * 1024 * 1024)
        let data = Data(buffer: buffer)
        return (data, contentType)
    }

    func getImageUrl(for item: BaseItemDto, imageType: ImageType, quality: Int = 85) -> String? {
        if imageType == .backdrop {
            guard let backdropTags = item.backdropImageTags, !backdropTags.isEmpty else {
                return nil
            }
            return "\(baseURL)/Items/\(item.id ?? "")/Images/Backdrop/0?quality=\(quality)&api_key=\(apiKey)"
        }

        guard let imageTags = item.imageTags, imageTags[imageType.rawValue] != nil else {
            return nil
        }

        return "\(baseURL)/Items/\(item.id ?? "")/Images/\(imageType.rawValue)?quality=\(quality)&api_key=\(apiKey)"
    }

    // MARK: - Server Info

    func getServerInfo() async throws -> JellyfinServerInfo {
        let url = "\(baseURL)/System/Info/Public"

        var request = HTTPClientRequest(url: url)
        request.method = .GET
        request.headers.add(name: "Accept", value: "application/json")

        let response = try await httpClient.execute(request, timeout: .seconds(10))

        guard response.status == .ok else {
            throw JellyfinError.requestFailed("Failed to fetch server info: \(response.status)")
        }

        let data = try await response.body.collect(upTo: 1024 * 1024)
        return try JSONDecoder().decode(JellyfinServerInfo.self, from: data)
    }

    func testConnection() async throws -> Bool {
        let url = "\(baseURL)/Users/\(userId)"

        var request = HTTPClientRequest(url: url)
        request.method = .GET
        request.headers.add(name: "Authorization", value: "MediaBrowser Token=\"\(apiKey)\"")

        let response = try await httpClient.execute(request, timeout: .seconds(10))
        return response.status == .ok
    }
}

// MARK: - Server Info DTO

struct JellyfinServerInfo: Codable, Sendable {
    let localAddress: String
    let serverName: String
    let version: String
    let productName: String
    let operatingSystem: String
    let id: String
    let startupWizardCompleted: Bool?

    enum CodingKeys: String, CodingKey {
        case localAddress = "LocalAddress"
        case serverName = "ServerName"
        case version = "Version"
        case productName = "ProductName"
        case operatingSystem = "OperatingSystem"
        case id = "Id"
        case startupWizardCompleted = "StartupWizardCompleted"
    }
}
