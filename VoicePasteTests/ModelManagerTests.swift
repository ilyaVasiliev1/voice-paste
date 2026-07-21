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
            makeTranscriber: { _, _, _ in MockTranscriber(result: .success(result)) }
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

    // MARK: - `AT-094`/`L-010`: "Удалить модель" in Settings

    /// From `.ready`: `deleteModel()` must unload from memory and drop the
    /// manager back to `.notPrepared` (`INV-015`: not-ready surface again)
    /// rather than to `.unloaded` (which would mean "still verified on
    /// disk").
    func test_deleteModel_fromReady_setsNotPrepared() async throws {
        let manager = makeManager()
        _ = try await manager.ensureLoaded()
        XCTAssertEqual(manager.state, .ready)

        manager.deleteModel()

        XCTAssertEqual(manager.state, .notPrepared)
        XCTAssertFalse(manager.isReady)
    }

    /// From `.unloaded` (model verified on disk but not resident in memory,
    /// e.g. right after `unloadNow()`): `deleteModel()` must still wipe the
    /// on-disk model and land on `.notPrepared`, not silently no-op because
    /// nothing was "loaded".
    func test_deleteModel_fromUnloaded_setsNotPrepared() async throws {
        let directory = try makeTempModelDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try makePlausibleModelFiles(in: directory)

        let manager = ModelManager(
            modelDirectory: directory,
            makeTranscriber: { _, _, _ in MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil))) }
        )
        XCTAssertEqual(manager.state, .unloaded, "starts detected as an already-verified local model")

        manager.deleteModel()

        XCTAssertEqual(manager.state, .notPrepared)
    }

    /// `AT-094`: after deletion, `Application Support/VoicePaste/Models`
    /// (here, the injected temp `modelDirectory`) must be genuinely empty on
    /// disk, not merely have its in-memory `state` changed. Seeds a stub
    /// model file first so the emptiness check is meaningful.
    func test_deleteModel_leavesModelDirectoryEmptyOnDisk() async throws {
        let directory = try makeTempModelDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try makePlausibleModelFiles(in: directory)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty,
            "sanity check: the stub model files must exist before deletion"
        )

        let manager = ModelManager(
            modelDirectory: directory,
            makeTranscriber: { _, _, _ in MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil))) }
        )

        manager.deleteModel()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.path),
            "the Models directory itself must still exist (recreated empty), not be gone entirely"
        )
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(remaining.isEmpty, "Models directory must be empty after deletion, found: \(remaining)")
    }

    /// Safety/idempotency: calling `deleteModel()` when nothing has ever been
    /// downloaded (`.notPrepared`, empty directory) must not crash and must
    /// leave the state exactly as it was — mirrors the doc comment's claim
    /// that this is "safe to call from any state".
    func test_deleteModel_fromNotPrepared_isIdempotent_noCrash() throws {
        let directory = try makeTempModelDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = ModelManager(
            modelDirectory: directory,
            makeTranscriber: { _, _, _ in MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil))) }
        )
        XCTAssertEqual(manager.state, .notPrepared)

        manager.deleteModel()
        manager.deleteModel() // called twice: must stay idempotent

        XCTAssertEqual(manager.state, .notPrepared)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(remaining.isEmpty)
    }

    /// `AT-094`/`L-010`: "история/словарь/настройки не затронуты". Simulates
    /// the real `Application Support/VoicePaste/` layout — a `Models`
    /// subdirectory next to sibling files representing history/dictionary/
    /// settings stores — and asserts `deleteModel()` only reaches inside
    /// `modelDirectory`, never touching its siblings. This is the behavioral
    /// proof backing `removeModelDirectoryContents()`'s doc comment claim
    /// that `modelDirectory` is "exclusively owned by this app for model
    /// storage" and the only thing `deleteModel()` removes.
    func test_deleteModel_doesNotTouchSiblingFilesOutsideModelDirectory() async throws {
        let appSupportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelManagerTests-AppSupport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupportRoot) }

        let modelsDirectory = appSupportRoot.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        try makePlausibleModelFiles(in: modelsDirectory)

        // Sibling stores that must never be touched by model deletion.
        let historyFile = appSupportRoot.appendingPathComponent("history.sqlite")
        let dictionaryFile = appSupportRoot.appendingPathComponent("dictionary.json")
        let settingsFile = appSupportRoot.appendingPathComponent("settings.plist")
        for file in [historyFile, dictionaryFile, settingsFile] {
            XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data("kept".utf8)))
        }

        let manager = ModelManager(
            modelDirectory: modelsDirectory,
            makeTranscriber: { _, _, _ in MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil))) }
        )
        _ = try await manager.ensureLoaded()

        manager.deleteModel()

        XCTAssertEqual(manager.state, .notPrepared)
        let remainingInModels = try FileManager.default.contentsOfDirectory(atPath: modelsDirectory.path)
        XCTAssertTrue(remainingInModels.isEmpty, "Models directory must be wiped")
        for file in [historyFile, dictionaryFile, settingsFile] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: file.path),
                "sibling store \(file.lastPathComponent) must survive model deletion untouched"
            )
            XCTAssertEqual(
                try Data(contentsOf: file), Data("kept".utf8),
                "sibling store \(file.lastPathComponent) content must be unchanged"
            )
        }
    }

    // MARK: - Startup detection of an already-downloaded model (`L-001`, `AT-004`)

    /// A fresh `modelDirectory` with no model files must still start
    /// `.notPrepared` — only a genuinely-missing model blocks readiness.
    func test_init_withEmptyModelDirectory_startsNotPrepared() throws {
        let directory = try makeTempModelDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = ModelManager(
            modelDirectory: directory,
            makeTranscriber: { _, _, _ in MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil))) }
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
            makeTranscriber: { _, _, _ in MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil))) }
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
            makeTranscriber: { _, _, _ in MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil))) }
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
            makeTranscriber: { _, _, _ in MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil))) }
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
            makeTranscriber: { _, _, _ in MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil))) }
        )

        XCTAssertEqual(manager.state, .notPrepared)
    }

    /// `ensureLoaded()` recovering from a corrupt-but-`LocalModelDetection`-
    /// verified local model: the load itself fails (mirrors WhisperKit's
    /// "Failed to parse ML Program" on a subtly-corrupt file), so the stale
    /// folder must be wiped and a fresh load attempted — landing on `.ready`
    /// rather than getting stuck in `.failed`.
    ///
    /// Adapted for `loadWithAutoRetry()`: a *single* failing attempt is no
    /// longer enough to reach this wipe path at all, because the blind
    /// auto-retry (`maxAutoDownloadRetries = 2`) now transparently retries
    /// the very same (still-corrupt) local folder up to 3 times *before*
    /// `ensureLoaded()`'s own catch block ever sees an error. To actually
    /// exercise the wipe-and-redownload branch, the factory must fail on
    /// *all 3* attempts of that first `loadWithAutoRetry()` session (i.e.
    /// the corruption is attempt-independent, as real "Failed to parse ML
    /// Program" corruption would be) — only then does `ensureLoaded()` wipe
    /// the folder and start a second `loadWithAutoRetry()` session, which
    /// succeeds on its first attempt against the now-clean directory. This
    /// makes the test ~3s slower (two 1.5s auto-retry pauses within the
    /// first session) but honestly exercises the real call path.
    func test_ensureLoaded_whenExistingLocalModelFailsToLoad_wipesAndRetries() async throws {
        let directory = try makeTempModelDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try makePlausibleModelFiles(in: directory)

        var attempt = 0
        let manager = ModelManager(
            modelDirectory: directory,
            makeTranscriber: { _, _, _ in
                attempt += 1
                if attempt <= 3 {
                    // Mirrors `WhisperKitTranscriber.init` throwing at load
                    // time (e.g. "Failed to parse ML Program") — the failure
                    // happens while constructing the engine, not later while
                    // transcribing. Fails on all 3 attempts of the first
                    // `loadWithAutoRetry()` session (the corrupt folder is
                    // still corrupt however many times it's retried), so
                    // that session's auto-retry budget is fully exhausted
                    // and `ensureLoaded()`'s wipe-and-redownload branch
                    // actually runs.
                    throw TranscribingError.underlying("corrupt model.mil")
                }
                return MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil)))
            }
        )
        XCTAssertEqual(manager.state, .unloaded, "starts detected as verified, exactly like the real regression")

        _ = try await manager.ensureLoaded()

        XCTAssertEqual(manager.state, .ready)
        XCTAssertEqual(attempt, 4, "3 exhausted attempts against the corrupt folder, then 1 successful attempt after the wipe")
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
