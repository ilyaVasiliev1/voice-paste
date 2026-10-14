import CryptoKit
import Foundation
import Testing

@testable import VoicePaste

/// Целостность скачанной модели: SHA-256 архива сверяется с вшитой суммой до
/// распаковки. Сети нет: архивы — локальные файлы, адрес `file://`.
@Suite("Контрольная сумма модели", .serialized)
struct ModelArchiveChecksumTests {

    // MARK: - Хеш файла

    private func temporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("checksum-\(UUID().uuidString).bin")
        try data.write(to: url)
        return url
    }

    @Test("известный вектор: «abc»")
    func knownVector() async throws {
        let url = try temporaryFile(Data("abc".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        let digest = try await FileDigest.sha256(of: url)

        #expect(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("пустой файл")
    func emptyFile() async throws {
        let url = try temporaryFile(Data())
        defer { try? FileManager.default.removeItem(at: url) }

        let digest = try await FileDigest.sha256(of: url)

        #expect(digest == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("файл не кратен размеру куска — сумма та же, что за один проход")
    func multiChunkFileMatchesOneShot() async throws {
        let bytes = (0..<(3 * 1_048_576 + 12_345)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) }
        let data = Data(bytes)
        let url = try temporaryFile(data)
        defer { try? FileManager.default.removeItem(at: url) }

        let digest = try await FileDigest.sha256(of: url)

        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == expected)
    }

    @Test("нет файла — ошибка, а не пустая сумма")
    func missingFileThrows() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString)")
        await #expect(throws: (any Error).self) {
            _ = try await FileDigest.sha256(of: url)
        }
    }

    // MARK: - Загрузчик

    /// Архив с одним вложенным файлом `payload/model.bin`.
    private func makeArchive(content: String) throws -> (zip: URL, sha256: String, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("src/payload", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: source.appendingPathComponent("model.bin"))

        let zip = root.appendingPathComponent("payload.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", source.path, zip.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)

        let digest = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
        return (zip, digest, root)
    }

    private func fetch(zip: URL, sha256: String, into root: URL) async throws -> URL {
        let destination = root.appendingPathComponent("installed", isDirectory: true)
        let downloader = GitHubModelDownloader(workDirectory: root.appendingPathComponent("work", isDirectory: true))
        let archive = GitHubModelDownloader.Archive(
            url: zip,
            destination: destination,
            expectedChild: "payload",
            progressWeight: 1.0,
            expectedSHA256: sha256
        )
        try await downloader.fetchAll([archive]) { _ in }
        return destination
    }

    @Test("верная сумма — архив распакован и установлен")
    func matchingChecksumInstalls() async throws {
        let archive = try makeArchive(content: "weights-v1")
        defer { try? FileManager.default.removeItem(at: archive.root) }

        let destination = try await fetch(zip: archive.zip, sha256: archive.sha256, into: archive.root)

        let installed = destination.appendingPathComponent("payload/model.bin")
        #expect(try String(contentsOf: installed, encoding: .utf8) == "weights-v1")
    }

    @Test("сумма в другом регистре тоже принимается")
    func uppercaseChecksumIsAccepted() async throws {
        let archive = try makeArchive(content: "weights-v1")
        defer { try? FileManager.default.removeItem(at: archive.root) }

        let destination = try await fetch(zip: archive.zip, sha256: archive.sha256.uppercased(), into: archive.root)

        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("payload").path))
    }

    @Test("чужая сумма — отказ, ничего не установлено, работа не повторяется с паузами", .timeLimit(.minutes(1)))
    func mismatchedChecksumIsRefusedWithoutInstalling() async throws {
        let archive = try makeArchive(content: "weights-v1")
        defer { try? FileManager.default.removeItem(at: archive.root) }
        let wrong = String(repeating: "0", count: 64)

        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: GitHubModelDownloader.DownloadError.checksumMismatch) {
            _ = try await fetch(zip: archive.zip, sha256: wrong, into: archive.root)
        }
        let elapsed = started.duration(to: clock.now)

        let installed = archive.root.appendingPathComponent("installed/payload")
        #expect(!FileManager.default.fileExists(atPath: installed.path))
        // Пять попыток с паузами заняли бы полминуты: несовпадение — не сбой сети.
        #expect(elapsed < .seconds(8))
    }

    // MARK: - Менеджер модели

    @Test("несовпадение суммы — отказ проверки, а не сбой сети")
    @MainActor
    func integrityFailureIsMappedToVerificationFailed() {
        let error = GitHubModelDownloader.DownloadError.checksumMismatch

        #expect(ModelManager.isIntegrityFailure(error))
        #expect(ModelManager.modelError(for: error) == .verificationFailed)
    }

    @Test("обычный сбой сети остаётся сбоем загрузки и повторяется")
    @MainActor
    func networkFailureStaysRetryable() {
        let error = GitHubModelDownloader.DownloadError.httpStatus(503)

        #expect(!ModelManager.isIntegrityFailure(error))
        #expect(ModelManager.modelError(for: error) == .downloadFailed)
        #expect(ModelManager.modelError(for: ModelError.insufficientStorage(requiredBytes: 1, availableBytes: 0))
            == .insufficientStorage(requiredBytes: 1, availableBytes: 0))
    }

    // MARK: - Каталог

    @Test("для обоих архивов закреплены суммы: 64 шестнадцатеричных знака")
    func catalogPinsBothArchives() {
        for digest in [ModelCatalog.githubModelArchiveSHA256, ModelCatalog.githubTokenizerArchiveSHA256] {
            #expect(digest.count == 64)
            #expect(digest.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        }
        #expect(ModelCatalog.githubModelArchiveSHA256 != ModelCatalog.githubTokenizerArchiveSHA256)
    }
}
