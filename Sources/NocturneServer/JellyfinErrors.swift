import Foundation

enum JellyfinError: Error, LocalizedError, Sendable {
    case authenticationFailed(String)
    case requestFailed(String)
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .authenticationFailed(let message):
            return "Authentication failed: \(message)"
        case .requestFailed(let message):
            return "Request failed: \(message)"
        case .httpError(let code, let message):
            return "HTTP Error (\(code)): \(message)"
        }
    }
}
