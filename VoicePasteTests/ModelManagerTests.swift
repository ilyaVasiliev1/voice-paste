import XCTest
@testable import VoicePaste

/// Gate 1 unit tests for `ModelManager`'s unload timer (`L-010`, `INV-011`).
///
/// `ModelManager` has no injectable clock — `endTask(unloadMinutes:)` always
/// schedules real wall-clock `Task.sleep(nanoseconds: minutes * 60s)`. Rather
/// than fake time (which would require product-code changes, out of scope
/// for QA), these tests either:
/// - exercise the parts of the logic that are observable without waiting
///   (the `0 == keep warm` guard, and `unloadNow()`'s immediate effect), or
/// - use `unloadMinutes: 1` and genuinely wait just over 60s — a real,
///   slightly slow, but honest test of `AT-026`/`AT-027` at the unit level.
@MainActor
final class ModelManagerTests: XCTestCase {

    private func makeManager(result: TranscriptionResult = .init(rawText: "", detectedLanguage: nil)) -> ModelManager {
        ModelManager(
            modelDirectory: FileManager.default.temporaryDirectory,
            makeTranscriber: { _, _ in MockTranscriber(result: .success(result)) }
        )
    }

    // MARK: - Fast, deterministic checks

    func test_ensureLoaded_reachesReady_andReturnsTranscriber() async throws {
        let manager = makeManager()
        XCTAssertEqual(manager.state, .notPrepared)

        _ = try await manager.ensureLoaded()

        XCTAssertTrue(manager.isReady)
        XCTAssertEqual(manager.state, .ready)
    }

    /// `AT-026`/quit: `unloadNow()` releases the model synchronously, no
    /// timer required. This is exactly the effect the 60s timer eventually
    /// triggers on its own.
    func test_unloadNow_releasesModel_immediately() async throws {
        let manager = makeManager()
        _ = try await manager.ensureLoaded()
        XCTAssertTrue(manager.isReady)

        manager.unloadNow()

        XCTAssertEqual(manager.state, .unloaded)
        XCTAssertFalse(manager.isReady)
    }

    /// `beginTask()` (a new recording/import starting) cancels any pending
    /// unload timer per `L-010`. Calling it with no timer scheduled must be
    /// harmless.
    func test_beginTask_withNoPendingTimer_isHarmless() async throws {
        let manager = makeManager()
        _ = try await manager.ensureLoaded()

        manager.beginTask()

        XCTAssertTrue(manager.isReady)
    }

    /// `AT-027` (`0 == keep warm`): scheduling with `0` minutes must never
    /// start an unload timer at all — verified by waiting a short, safe
    /// window and confirming the model is still ready (a real bug that
    /// scheduled e.g. a 0-length timer would already have fired well within
    /// this window).
    func test_endTask_zeroMinutes_neverSchedulesUnload() async throws {
        let manager = makeManager()
        _ = try await manager.ensureLoaded()

        manager.endTask(unloadMinutes: 0)
        try await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s

        XCTAssertTrue(manager.isReady)
        XCTAssertEqual(manager.state, .ready)
    }

    func test_endTask_negativeMinutes_alsoNeverSchedulesUnload() async throws {
        let manager = makeManager()
        _ = try await manager.ensureLoaded()

        manager.endTask(unloadMinutes: -1)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertTrue(manager.isReady)
    }

    // MARK: - Startup detection of an already-downloaded model (`L-001`, `AT-004`)

    /// A fresh `modelDirectory` with no model files must still start
    /// `.notPrepared` — only a genuinely-missing model blocks readiness.
    func test_init_withEmptyModelDirectory_startsNotPrepared() throws {
        let directory = try makeTempModelDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = ModelManager(
            modelDirectory: directory,
            makeTranscriber: { _, _ in MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil))) }
        )

        XCTAssertEqual(manager.state, .notPrepared)
    }

    /// `AT-004`: a previous run's verified model files already on disk must
    /// be detected at startup as `.unloaded` (verified, lazily reloadable),
    /// never re-triggering the 626 MB download path.
    func test_init_withVerifiedModelFilesOnDisk_startsUnloaded_notNotPrepared() throws {
        let directory = try makeTempModelDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try makePlausibleModelFiles(in: directory)

        let manager = ModelManager(
            modelDirectory: directory,
            makeTranscriber: { _, _ in MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil))) }
        )

        XCTAssertEqual(manager.state, .unloaded)
    }

    /// A partial download (missing one required component) must not be
    /// mistaken for a verified model.
    func test_init_withIncompleteModelFiles_startsNotPrepared() throws {
        let directory = try makeTempModelDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("MelSpectrogram.mlmodelc"),
            withIntermediateDirectories: true
        )

        let manager = ModelManager(
            modelDirectory: directory,
            makeTranscriber: { _, _ in MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil))) }
        )

        XCTAssertEqual(manager.state, .notPrepared)
    }

    /// The exact real-world regression this fix targets: folder skeletons
    /// with tiny stub files (no `model.mil`, no weights — as WhisperKit
    /// itself would leave behind from a torn/interrupted download) must NOT
    /// be mistaken for a verified model, even though the `.mlmodelc`
    /// directories themselves exist.
    func test_init_withStubModelFolders_noModelMil_startsNotPrepared() throws {
        let directory = try makeTempModelDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            let componentDirectory = directory.appendingPathComponent("\(name).mlmodelc")
            try FileManager.default.createDirectory(at: componentDirectory, withIntermediateDirectories: true)
            // A torn download's leftover: a tiny placeholder, no `model.mil`.
            FileManager.default.createFile(
                atPath: componentDirectory.appendingPathComponent("coremldata.bin").path,
                contents: Data(repeating: 0, count: 329)
            )
        }

        let manager = ModelManager(
            modelDirectory: directory,
            makeTranscriber: { _, _ in MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil))) }
        )

        XCTAssertEqual(manager.state, .notPrepared)
    }

    /// Even with a `model.mil` present in each component, a folder whose
    /// total size is implausibly small for a real model must not pass —
    /// guards against a different kind of torn download that got as far as
    /// creating (near-)empty `model.mil` files.
    func test_init_withTinyModelMilFiles_belowSizeThreshold_startsNotPrepared() throws {
        let directory = try makeTempModelDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            let componentDirectory = directory.appendingPathComponent("\(name).mlmodelc")
            try FileManager.default.createDirectory(at: componentDirectory, withIntermediateDirectories: true)
            FileManager.default.createFile(
                atPath: componentDirectory.appendingPathComponent("model.mil").path,
                contents: Data(repeating: 0, count: 64)
            )
        }

        let manager = ModelManager(
            modelDirectory: directory,
            makeTranscriber: { _, _ in MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil))) }
        )

        XCTAssertEqual(manager.state, .notPrepared)
    }

    /// `ensureLoaded()` recovering from a corrupt-but-`LocalModelDetection`-
    /// verified local model: the load itself fails (mirrors WhisperKit's
    /// "Failed to parse ML Program" on a subtly-corrupt file), so the stale
    /// folder must be wiped and a fresh load attempted — landing on `.ready`
    /// rather than getting stuck in `.failed`.
    func test_ensureLoaded_whenExistingLocalModelFailsToLoad_wipesAndRetries() async throws {
        let directory = try makeTempModelDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try makePlausibleModelFiles(in: directory)

        var attempt = 0
        let manager = ModelManager(
            modelDirectory: directory,
            makeTranscriber: { _, _ in
                attempt += 1
                if attempt == 1 {
                    // Mirrors `WhisperKitTranscriber.init` throwing at load
                    // time (e.g. "Failed to parse ML Program") — the failure
                    // happens while constructing the engine, not later while
                    // transcribing.
                    throw TranscribingError.underlying("corrupt model.mil")
                }
                return MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil)))
            }
        )
        XCTAssertEqual(manager.state, .unloaded, "starts detected as verified, exactly like the real regression")

        _ = try await manager.ensureLoaded()

        XCTAssertEqual(manager.state, .ready)
        XCTAssertEqual(attempt, 2, "must have retried once after wiping the invalid folder")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("MelSpectrogram.mlmodelc").path),
            "the invalid folder must have been wiped, not left behind"
        )
    }

    private func makeTempModelDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Writes stub component folders whose `model.mil` files are each large
    /// enough (via a sparse file, so it's instant and doesn't actually use
    /// disk) to clear `LocalModelDetection.minimumPlausibleTotalBytes` when
    /// summed across all three required components.
    private func makePlausibleModelFiles(in directory: URL) throws {
        let perComponentBytes = LocalModelDetection.minimumPlausibleTotalBytes / 3 + 1024
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            let componentDirectory = directory.appendingPathComponent("\(name).mlmodelc")
            try FileManager.default.createDirectory(at: componentDirectory, withIntermediateDirectories: true)
            let modelMilPath = componentDirectory.appendingPathComponent("model.mil").path
            FileManager.default.createFile(atPath: modelMilPath, contents: nil)
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: modelMilPath))
            try handle.truncate(atOffset: UInt64(perComponentBytes))
            try handle.close()
        }
    }

    // MARK: - Real-time timer behavior (slow: ~61s total for both assertions)

    /// `AT-026` (fires) and the cancellation half of `L-010` ("новая
    /// запись/импорт отменяет таймер"), run concurrently so the suite only
    /// pays the ~61s wall-clock cost once.
    func test_unloadTimer_firesAfterOneMinute_unlessCancelledByNewTask() async throws {
        let firingManager = makeManager()
        _ = try await firingManager.ensureLoaded()
        firingManager.endTask(unloadMinutes: 1)

        let cancellingManager = makeManager()
        _ = try await cancellingManager.ensureLoaded()
        cancellingManager.endTask(unloadMinutes: 1)
        // A new recording/import starts right away: must cancel the pending
        // unload timer (`L-010`).
        cancellingManager.beginTask()

        try await Task.sleep(nanoseconds: 61_000_000_000) // 61s > the 60s timer

        XCTAssertEqual(firingManager.state, .unloaded, "AT-026: timer must have unloaded the model after 1 minute.")
        XCTAssertEqual(
            cancellingManager.state, .ready,
            "L-010: beginTask() must have cancelled the pending unload timer."
        )
    }
}
