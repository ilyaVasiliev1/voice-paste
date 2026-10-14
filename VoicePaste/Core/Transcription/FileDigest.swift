import CryptoKit
import Foundation

/// SHA-256 файла. Модель весит сотни мегабайт, поэтому файл читается кусками,
/// а не целиком в память, и вне вызывающего актора.
nonisolated public enum FileDigest {
    private static let chunkSize = 1 << 20

    /// Строчные шестнадцатеричные знаки.
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
