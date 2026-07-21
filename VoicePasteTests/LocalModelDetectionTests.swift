import XCTest
@testable import VoicePaste

/// Unit tests for `LocalModelDetection`'s "verified on disk" criterion
/// (`L-001`/`AT-004`), including the hardening against a torn/stub download
/// that only leaves behind empty `.mlmodelc` folder scaffolding (the
/// real-world regression: "Failed to parse ML Program … model.mil cannot be
/// read" from a 36 KB placeholder masquerading as the 626 MB model).
@MainActor
final class LocalModelDetectionTests: XCTestCase {
    private let requiredComponents = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]

    func test_discoverModelFolder_emptyDirectory_returnsNil() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertNil(LocalModelDetection.discoverModelFolder(in: directory))
    }

    /// The exact regression: folders exist, but only tiny stub files inside
    /// (no `model.mil` at all) — must not be mistaken for a verified model.
    func test_discoverModelFolder_stubFoldersWithoutModelMil_returnsNil() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in requiredComponents {
            let componentDirectory = directory.appendingPathComponent("\(name).mlmodelc")
            try FileManager.default.createDirectory(at: componentDirectory, withIntermediateDirectories: true)
            FileManager.default.createFile(
                atPath: componentDirectory.appendingPathComponent("coremldata.bin").path,
                contents: Data(repeating: 0, count: 329)
            )
        }

        XCTAssertNil(LocalModelDetection.discoverModelFolder(in: directory))
    }

    /// `model.mil` present but the overall folder is implausibly small for a
    /// real model — also must not pass.
    func test_discoverModelFolder_tinyModelMilFiles_returnsNil() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in requiredComponents {
            let componentDirectory = directory.appendingPathComponent("\(name).mlmodelc")
            try FileManager.default.createDirectory(at: componentDirectory, withIntermediateDirectories: true)
            FileManager.default.createFile(
                atPath: componentDirectory.appendingPathComponent("model.mil").path,
                contents: Data(repeating: 0, count: 64)
            )
        }

        XCTAssertNil(LocalModelDetection.discoverModelFolder(in: directory))
    }

    /// A folder with real (sparse, for test speed) `model.mil` files whose
    /// combined size clears the plausibility floor must be discovered.
    func test_discoverModelFolder_plausibleModelMilFiles_returnsFolder() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try makePlausibleModelFiles(in: directory)

        let found = LocalModelDetection.discoverModelFolder(in: directory)

        XCTAssertEqual(found, directory)
    }

    /// WhisperKit nests the model a few levels below the download base
    /// (`<downloadBase>/models/argmaxinc/whisperkit-coreml/<variant>`); a
    /// valid model there must still be discovered by walking subfolders.
    func test_discoverModelFolder_nestedPlausibleModel_returnsNestedFolder() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nested = directory
            .appendingPathComponent("models")
            .appendingPathComponent("argmaxinc")
            .appendingPathComponent("whisperkit-coreml")
            .appendingPathComponent("openai_whisper-large-v3-v20240930_626MB")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try makePlausibleModelFiles(in: nested)

        let found = LocalModelDetection.discoverModelFolder(in: directory)

        // Compare standardized paths: `FileManager.temporaryDirectory` on
        // macOS resolves through a `/var` -> `/private/var` symlink, which
        // `discoverModelFolder`'s directory walk may or may not preserve
        // depending on enumeration order — irrelevant to the behavior under
        // test (finding the right nested folder).
        XCTAssertEqual(found?.standardizedFileURL.path, nested.standardizedFileURL.path)
    }

    /// A partial download (missing one required component) must not be
    /// mistaken for a verified model even if the others are plausible.
    func test_discoverModelFolder_missingOneComponent_returnsNil() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["MelSpectrogram", "AudioEncoder"] {
            let componentDirectory = directory.appendingPathComponent("\(name).mlmodelc")
            try FileManager.default.createDirectory(at: componentDirectory, withIntermediateDirectories: true)
            let path = componentDirectory.appendingPathComponent("model.mil").path
            FileManager.default.createFile(atPath: path, contents: nil)
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try handle.truncate(atOffset: UInt64(LocalModelDetection.minimumPlausibleTotalBytes))
            try handle.close()
        }

        XCTAssertNil(LocalModelDetection.discoverModelFolder(in: directory))
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalModelDetectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Writes stub component folders whose `model.mil` files are each large
    /// enough (via a sparse file, so it's instant and doesn't actually use
    /// disk) to clear `LocalModelDetection.minimumPlausibleTotalBytes` when
    /// summed across all three required components.
    private func makePlausibleModelFiles(in directory: URL) throws {
        let perComponentBytes = LocalModelDetection.minimumPlausibleTotalBytes / 3 + 1024
        for name in requiredComponents {
            let componentDirectory = directory.appendingPathComponent("\(name).mlmodelc")
            try FileManager.default.createDirectory(at: componentDirectory, withIntermediateDirectories: true)
            let modelMilPath = componentDirectory.appendingPathComponent("model.mil").path
            FileManager.default.createFile(atPath: modelMilPath, contents: nil)
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: modelMilPath))
            try handle.truncate(atOffset: UInt64(perComponentBytes))
            try handle.close()
        }
    }
}
