import Foundation

// Minimal Jellyfin DTO surface — only what RasaServer actually decodes.
//
// We talk to Jellyfin for four things:
//   1. Login (AuthenticationResult → token + user id)
//   2. List movie IDs (JellyfinItemsResponse → [BaseItemDto].id)
//   3. Fetch one movie for the LLM prompt + admin proxy (BaseItemDto)
//   4. Build image URLs from BaseItemDto.imageTags / backdropImageTags
//
// Everything else (playback, sessions, device profiles, user policy, media streams, …) was
// removed when the client took over the Jellyfin-SDK responsibilities.

struct JellyfinItemsResponse: Codable, Sendable {
    let items: [BaseItemDto]?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

struct BaseItemDto: Codable, Sendable {
    let id: String?
    let name: String?
    let originalTitle: String?
    let overview: String?
    let productionYear: Int?
    let runTimeTicks: Int64?
    let genres: [String]?
    let people: [BaseItemPerson]?
    let imageTags: [String: String]?
    let backdropImageTags: [String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case originalTitle = "OriginalTitle"
        case overview = "Overview"
        case productionYear = "ProductionYear"
        case runTimeTicks = "RunTimeTicks"
        case genres = "Genres"
        case people = "People"
        case imageTags = "ImageTags"
        case backdropImageTags = "BackdropImageTags"
    }
}

struct BaseItemPerson: Codable, Sendable {
    let name: String?
    let id: String?
    let role: String?
    let type: String?
    let primaryImageTag: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case id = "Id"
        case role = "Role"
        case type = "Type"
        case primaryImageTag = "PrimaryImageTag"
    }
}

enum ImageType: String, Codable, Sendable {
    case primary = "Primary"
    case backdrop = "Backdrop"
    case logo = "Logo"
    case thumb = "Thumb"
}

// MARK: - Authentication

struct AuthenticationResult: Codable, Sendable {
    let user: AuthenticatedUser?
    let accessToken: String?

    enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
    }
}

struct AuthenticatedUser: Codable, Sendable {
    let id: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
    }
}
