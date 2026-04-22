import Foundation
import Crypto
import Logging

enum SecretsError: Error { case keyReadFailed, keyWriteFailed, invalidBase64 }

struct SecretsManager {
    static func loadOrCreateKey(path: String = "secrets/master.key", logger: Logger? = nil) throws -> SymmetricKey {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: dir) {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: path) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let str = String(data: data, encoding: .utf8), let keyData = Data(base64Encoded: str.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw SecretsError.keyReadFailed
            }
            return SymmetricKey(data: keyData)
        } else {
            // 32 random bytes (cross-platform)
            #if canImport(Security)
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            let keyData = Data(bytes)
            #else
            let keyData = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            #endif
            let b64 = keyData.base64EncodedString()
            guard let outData = b64.data(using: .utf8) else { throw SecretsError.keyWriteFailed }
            fm.createFile(atPath: path, contents: outData, attributes: [.posixPermissions: 0o600])
            logger?.info("Created master key at \(path)")
            return SymmetricKey(data: keyData)
        }
    }
    
    static func encryptString(_ plaintext: String, key: SymmetricKey) throws -> String {
        let nonce =  AES.GCM.Nonce() // random
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key, nonce: nonce)
        guard let combined = sealed.combined else { throw SecretsError.keyWriteFailed }
        return combined.base64EncodedString()
    }
    
    static func decryptString(_ base64: String, key: SymmetricKey) throws -> String {
        guard let combined = Data(base64Encoded: base64) else { throw SecretsError.invalidBase64 }
        let box = try AES.GCM.SealedBox(combined: combined)
        let data = try AES.GCM.open(box, using: key)
        return String(decoding: data, as: UTF8.self)
    }
}


