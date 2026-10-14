import CryptoKit
import Foundation

nonisolated public enum FileDigest {
    private static let chunkSize = 1 << 20

    /// SHA-256 файла строчными шестнадцатеричными знаками; читается кусками — модель весит сотни МБ.
    @concurrent
    public static func sha256(of url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
