import Foundation
import Logging

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Jellyfin server auto-discovery using the standard client-discovery protocol.
///
/// Sends a UDP broadcast (`"Who is JellyfinServer?"`) to `255.255.255.255:7359`
/// and collects JSON replies for a short window. This matches the protocol used
/// by the official Jellyfin mobile/web clients and is supported by every
/// reasonably recent Jellyfin server (>= 10.x) without any extra configuration.
///
/// Deliberately POSIX-sockets-based so it works on macOS and Linux (the Pi
/// target) without bringing in SwiftNIO or the Apple-only Network framework.
enum JellyfinDiscovery {

    struct Server: Codable, Sendable {
        let id: String
        let name: String
        let address: String
        let version: String?
    }

    /// Jellyfin's on-wire response shape (PascalCase field names).
    private struct JellyfinResponse: Codable {
        let address: String?
        let id: String?
        let name: String?
        let endpointAddress: String?

        enum CodingKeys: String, CodingKey {
            case address = "Address"
            case id = "Id"
            case name = "Name"
            case endpointAddress = "EndpointAddress"
        }
    }

    /// Broadcast and collect responses. Returns deduped servers by ID.
    /// - Parameter timeoutMs: how long to listen after the broadcast.
    static func discover(timeoutMs: Int = 2000) async throws -> [Server] {
        let logger = Logger(label: "JellyfinDiscovery")

        // Run the blocking socket work on a background task so we don't stall
        // the Hummingbird event loop.
        return try await Task.detached(priority: .userInitiated) {
            try performDiscovery(timeoutMs: timeoutMs, logger: logger)
        }.value
    }

    private static func performDiscovery(timeoutMs: Int, logger: Logger) throws -> [Server] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            throw DiscoveryError.socketFailed(errno)
        }
        defer { close(fd) }

        // Enable broadcast.
        var yes: Int32 = 1
        if setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size)) < 0 {
            throw DiscoveryError.setsockoptFailed(errno)
        }

        // Bind to an ephemeral local port (needed so recvfrom sees replies).
        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        local.sin_addr.s_addr = inaddr_any()
        #if canImport(Darwin)
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let bindResult = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult < 0 {
            throw DiscoveryError.bindFailed(errno)
        }

        // Build the destination (255.255.255.255:7359).
        var dst = sockaddr_in()
        dst.sin_family = sa_family_t(AF_INET)
        dst.sin_port = in_port_t(7359).bigEndian
        dst.sin_addr.s_addr = 0xFFFFFFFF // INADDR_BROADCAST
        #if canImport(Darwin)
        dst.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif

        let message = "Who is JellyfinServer?"
        let messageBytes = Array(message.utf8)
        let sent = messageBytes.withUnsafeBufferPointer { buf -> ssize_t in
            withUnsafePointer(to: &dst) { dstPtr in
                dstPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    sendto(fd, buf.baseAddress, buf.count, 0, sockPtr,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 {
            throw DiscoveryError.sendFailed(errno)
        }

        // Listen for replies up to `timeoutMs`.
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        var servers: [String: Server] = [:]
        var buffer = [UInt8](repeating: 0, count: 4096)

        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            var tv = timeval(
                tv_sec: Int(remaining),
                tv_usec: Int32((remaining - Double(Int(remaining))) * 1_000_000)
            )
            var readSet = fd_set()
            fdZero(&readSet)
            fdSet(fd, set: &readSet)
            let ready = select(fd + 1, &readSet, nil, nil, &tv)
            if ready <= 0 { break }
            if !fdIsSet(fd, set: &readSet) { continue }

            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = buffer.withUnsafeMutableBufferPointer { buf -> ssize_t in
                withUnsafeMutablePointer(to: &from) { fromPtr in
                    fromPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        recvfrom(fd, buf.baseAddress, buf.count, 0, sockPtr, &fromLen)
                    }
                }
            }
            guard received > 0 else { continue }
            let data = Data(bytes: buffer, count: Int(received))

            if let parsed = try? JSONDecoder().decode(JellyfinResponse.self, from: data),
               let id = parsed.id, let name = parsed.name, let address = parsed.address {
                if servers[id] == nil {
                    servers[id] = Server(id: id, name: name, address: address, version: nil)
                }
            } else {
                logger.debug("Ignoring non-Jellyfin UDP reply (\(received) bytes)")
            }
        }

        return Array(servers.values).sorted { $0.name < $1.name }
    }

    enum DiscoveryError: Error, CustomStringConvertible {
        case socketFailed(Int32)
        case setsockoptFailed(Int32)
        case bindFailed(Int32)
        case sendFailed(Int32)

        var description: String {
            switch self {
            case .socketFailed(let e): return "socket() failed: errno=\(e)"
            case .setsockoptFailed(let e): return "setsockopt(SO_BROADCAST) failed: errno=\(e)"
            case .bindFailed(let e): return "bind() failed: errno=\(e)"
            case .sendFailed(let e): return "sendto() failed: errno=\(e)"
            }
        }
    }
}

// MARK: - Cross-platform fd_set helpers
// The `FD_SET`/`FD_ZERO`/`FD_ISSET` C macros aren't imported into Swift; these
// implement the same bit-twiddling by hand. `fd_set` on macOS/Linux is an array
// of __int32_t with FD_SETSIZE (typically 1024) bits.

private func inaddr_any() -> in_addr_t { return 0 }

private func fdZero(_ set: inout fd_set) {
    withUnsafeMutablePointer(to: &set) {
        memset($0, 0, MemoryLayout<fd_set>.size)
    }
}

private func fdSet(_ fd: Int32, set: inout fd_set) {
    let intOffset = Int(fd / 32)
    let bitOffset = Int(fd % 32)
    let mask: Int32 = 1 << bitOffset
    withUnsafeMutablePointer(to: &set) { setPtr in
        setPtr.withMemoryRebound(to: Int32.self, capacity: Int(FD_SETSIZE) / 32) { ptr in
            ptr[intOffset] |= mask
        }
    }
}

private func fdIsSet(_ fd: Int32, set: inout fd_set) -> Bool {
    let intOffset = Int(fd / 32)
    let bitOffset = Int(fd % 32)
    let mask: Int32 = 1 << bitOffset
    return withUnsafeMutablePointer(to: &set) { setPtr in
        setPtr.withMemoryRebound(to: Int32.self, capacity: Int(FD_SETSIZE) / 32) { ptr in
            (ptr[intOffset] & mask) != 0
        }
    }
}
