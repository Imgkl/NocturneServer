import Foundation
import Logging

/// On-disk LRU cache for Jellyfin poster bytes.
///
/// Keyed by `"{jellyfinId}-{size}"`. Files are stored as `.bin` on disk; the
/// original `Content-Type` is recorded in a sidecar `.ct` file so the response
/// can echo it back (Jellyfin may return JPEG or WebP depending on `Accept`).
///
/// Eviction runs after every write: when total size exceeds `maxBytes`, files
/// are deleted in order of oldest modification time until the cap is restored.
final class PosterCache: @unchecked Sendable {
    private let dir: URL
    private let maxBytes: Int64
    private let logger = Logger(label: "PosterCache")
    private let lock = NSLock()

    init(dir: String, maxBytes: Int64) throws {
        self.dir = URL(fileURLWithPath: dir)
        self.maxBytes = maxBytes
        try FileManager.default.createDirectory(at: self.dir, withIntermediateDirectories: true)
        logger.info("PosterCache at \(dir) (cap \(maxBytes) bytes)")
    }

    struct Entry {
        let data: Data
        let contentType: String
    }

    func get(key: String) -> Entry? {
        let (binURL, ctURL) = urls(for: key)
        guard FileManager.default.fileExists(atPath: binURL.path) else { return nil }
        // Touch mtime so LRU treats this as hot.
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: binURL.path)
        guard let data = try? Data(contentsOf: binURL) else { return nil }
        let contentType = (try? String(contentsOf: ctURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "image/jpeg"
        return Entry(data: data, contentType: contentType)
    }

    func set(key: String, data: Data, contentType: String) {
        let (binURL, ctURL) = urls(for: key)
        do {
            try data.write(to: binURL, options: .atomic)
            try contentType.write(to: ctURL, atomically: true, encoding: .utf8)
        } catch {
            logger.warning("PosterCache write failed for \(key): \(error)")
            return
        }
        evictIfNeeded()
    }

    // MARK: - Private

    private func urls(for key: String) -> (bin: URL, ct: URL) {
        // Sanitize: only allow [A-Za-z0-9_-] from the composed key.
        let safe = key.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                return Character(scalar)
            }
            return "_"
        }.reduce(into: "") { $0.append($1) }
        return (dir.appendingPathComponent("\(safe).bin"),
                dir.appendingPathComponent("\(safe).ct"))
    }

    private func evictIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let contents = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys) else { return }
        let binFiles = contents.filter { $0.pathExtension == "bin" }
        var files: [(url: URL, size: Int64, mtime: Date)] = []
        var totalSize: Int64 = 0
        for url in binFiles {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let size = Int64(values.fileSize ?? 0)
            let mtime = values.contentModificationDate ?? .distantPast
            files.append((url, size, mtime))
            totalSize += size
        }
        guard totalSize > maxBytes else { return }
        // Oldest first, delete until under cap.
        let sorted = files.sorted { $0.mtime < $1.mtime }
        var current = totalSize
        for (url, size, _) in sorted {
            if current <= maxBytes { break }
            try? fm.removeItem(at: url)
            // Sidecar too.
            let ct = url.deletingPathExtension().appendingPathExtension("ct")
            try? fm.removeItem(at: ct)
            current -= size
        }
        logger.info("PosterCache evicted to \(current) bytes (cap \(maxBytes))")
    }
}
