import XCTest

@testable import VoicePaste

private actor ModelFactoryInvocationFlag {
  private var wasCalled = false
  func set() { wasCalled = true }
  func get() -> Bool { wasCalled }
}

private actor ModelFactoryInvocationCounter {
  private var count = 0
  func increment() { count += 1 }
  func get() -> Int { count }
}

/// Gate 1 unit tests for `ModelManager`'s unload timer (`L-010`, `INV-011`).
///
/// Timer tests use the same production `Task.sleep` path with a shorter
/// injected duration, so the suite checks real cancellation semantics without
/// paying a minute of wall-clock time on every change.
@MainActor
final class ModelManagerTests: XCTestCase {

  private func makeManager(
    result: TranscriptionResult = .init(rawText: "", detectedLanguage: nil),
    unloadNanosecondsPerMinute: UInt64 = 60_000_000_000
  ) -> ModelManager {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ModelManagerTests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: directory)
    }
    return ModelManager(
      modelDirectory: directory,
      makeTranscriber: { _, _, _ in MockTranscriber(result: .success(result)) },
      unloadNanosecondsPerMinute: unloadNanosecondsPerMinute
    )
  }

  // MARK: - Fast, deterministic checks

  func test_installModel_reachesReady_andReturnsTranscriber() async throws {
    let manager = makeManager()
    XCTAssertEqual(manager.state, .notPrepared)

    _ = try await manager.installModel()

    XCTAssertTrue(manager.isReady)
    XCTAssertEqual(manager.state, .ready)
  }

  /// `AT-099`: once onboarding/readiness schedules a background pre-warm,
  /// repeated readiness refreshes and an immediately-started dictation must
  /// all join the same model load instead of compiling Core ML twice.
  func test_AT099_repeatedPrewarmAndFirstUseShareOneLoad() async throws {
    let directory = try makeTempModelDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try makePlausibleModelFiles(in: directory)
    try makeTokenizerFile(in: directory)
    let invocations = ModelFactoryInvocationCounter()
    let manager = ModelManager(
      modelDirectory: directory,
      makeTranscriber: { _, _, _ in
        await invocations.increment()
        try await Task.sleep(for: .milliseconds(100))
        return MockTranscriber()
      },
      allowsNetworkDownloads: false
    )
    await manager.waitForInitialModelDiscoveryForTesting()
    XCTAssertEqual(manager.state, .unloaded)

    manager.prewarm()
    manager.prewarm()
    _ = try await manager.ensureLoaded()

    XCTAssertEqual(manager.state, .ready)
    let invocationCount = await invocations.get()
    XCTAssertEqual(invocationCount, 1)
  }

  func test_AT099_runtimeLocalLoadReceivesNonNetworkEndpoint() async throws {
    let directory = try makeTempModelDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try makePlausibleModelFiles(in: directory)
    try makeTokenizerFile(in: directory)
    var receivedEndpoint: String?
    let manager = ModelManager(
      modelDirectory: directory,
      makeTranscriber: { _, endpoint, _ in
        receivedEndpoint = endpoint
        return MockTranscriber()
      },
      downloadEndpointProvider: { "https://must-not-be-used.example" }
    )
    await manager.waitForInitialModelDiscoveryForTesting()

    _ = try await manager.ensureLoaded()

    XCTAssertEqual(receivedEndpoint, ModelCatalog.offlineEndpoint)
    XCTAssertFalse(receivedEndpoint?.hasPrefix("http") == true)
  }

  /// `AT-026`/quit: `unloadNow()` releases the model synchronously, no
  /// timer required. This is exactly the effect the 60s timer eventually
  /// triggers on its own.
  func test_unloadNow_releasesModel_immediately() async throws {
    let manager = makeManager()
    _ = try await manager.installModel()
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
    _ = try await manager.installModel()

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
    _ = try await manager.installModel()

    manager.endTask(unloadMinutes: 0)
    try await Task.sleep(nanoseconds: 1_500_000_000)  // 1.5s

    XCTAssertTrue(manager.isReady)
    XCTAssertEqual(manager.state, .ready)
  }

  func test_endTask_negativeMinutes_alsoNeverSchedulesUnload() async throws {
    let manager = makeManager()
    _ = try await manager.installModel()

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
    _ = try await manager.installModel()
    XCTAssertEqual(manager.state, .ready)

    await manager.deleteModel()

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
    try makeTokenizerFile(in: directory)

    let manager = ModelManager(
      modelDirectory: directory,
      makeTranscriber: { _, _, _ in
        MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil)))
      }
    )
    await manager.waitForInitialModelDiscoveryForTesting()
    XCTAssertEqual(manager.state, .unloaded, "starts detected as an already-verified local model")

    await manager.deleteModel()

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
    try makeTokenizerFile(in: directory)
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty,
      "sanity check: the stub model files must exist before deletion"
    )

    let manager = ModelManager(
      modelDirectory: directory,
      makeTranscriber: { _, _, _ in
        MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil)))
      }
    )

    await manager.deleteModel()

    XCTAssertTrue(
      FileManager.default.fileExists(atPath: directory.path),
      "the Models directory itself must still exist (recreated empty), not be gone entirely"
    )
    let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    XCTAssertTrue(
      remaining.isEmpty, "Models directory must be empty after deletion, found: \(remaining)")
  }

  /// Safety/idempotency: calling `deleteModel()` when nothing has ever been
  /// downloaded (`.notPrepared`, empty directory) must not crash and must
  /// leave the state exactly as it was — mirrors the doc comment's claim
  /// that this is "safe to call from any state".
  func test_deleteModel_fromNotPrepared_isIdempotent_noCrash() async throws {
    let directory = try makeTempModelDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let manager = ModelManager(
      modelDirectory: directory,
      makeTranscriber: { _, _, _ in
        MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil)))
      }
    )
    XCTAssertEqual(manager.state, .notPrepared)

    await manager.deleteModel()
    await manager.deleteModel()  // called twice: must stay idempotent

    XCTAssertEqual(manager.state, .notPrepared)
    let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    XCTAssertTrue(remaining.isEmpty)
  }

  func test_deleteModel_invalidatesLateFinishingLoad() async throws {
    let directory = try makeTempModelDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = ModelManager(
      modelDirectory: directory,
      makeTranscriber: { _, _, _ in
        // Deliberately ignore cancellation to emulate Core ML work
        // which can finish after its awaiting task was cancelled.
        try? await Task.sleep(for: .milliseconds(250))
        return MockTranscriber()
      }
    )

    let loading = Task { try? await manager.installModel() }
    try await Task.sleep(for: .milliseconds(40))
    await manager.deleteModel()
    _ = await loading.value

    XCTAssertEqual(manager.state, .notPrepared)
    XCTAssertFalse(manager.isReady)
  }

  func test_AT099_runtimeLoadNeverInvokesFactoryWhenArtifactsAreMissing() async throws {
    let directory = try makeTempModelDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let factoryCalled = ModelFactoryInvocationFlag()
    let manager = ModelManager(
      modelDirectory: directory,
      makeTranscriber: { _, _, _ in
        await factoryCalled.set()
        return MockTranscriber()
      }
    )

    do {
      _ = try await manager.ensureLoaded()
      XCTFail("Missing offline artifacts must fail locally")
    } catch ModelError.verificationFailed {
      // expected
    }

    let wasCalled = await factoryCalled.get()
    XCTAssertFalse(wasCalled)
    XCTAssertEqual(manager.state, .failed(.verificationFailed))
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
      .appendingPathComponent(
        "ModelManagerTests-AppSupport-\(UUID().uuidString)", isDirectory: true)
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
      makeTranscriber: { _, _, _ in
        MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil)))
      }
    )
    _ = try await manager.installModel()

    await manager.deleteModel()

    XCTAssertEqual(manager.state, .notPrepared)
    let remainingInModels = try FileManager.default.contentsOfDirectory(
      atPath: modelsDirectory.path)
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
      makeTranscriber: { _, _, _ in
        MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil)))
      }
    )

    XCTAssertEqual(manager.state, .notPrepared)
  }

  /// `AT-004`: a previous run's verified model files already on disk must
  /// be detected at startup as `.unloaded` (verified, lazily reloadable),
  /// never re-triggering the 626 MB download path.
  func test_init_withVerifiedModelFilesOnDisk_startsUnloaded_notNotPrepared() async throws {
    let directory = try makeTempModelDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try makePlausibleModelFiles(in: directory)
    try makeTokenizerFile(in: directory)

    let manager = ModelManager(
      modelDirectory: directory,
      makeTranscriber: { _, _, _ in
        MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil)))
      }
    )

    await manager.waitForInitialModelDiscoveryForTesting()
    XCTAssertEqual(manager.state, .unloaded)
  }

  func test_init_withModelButMissingTokenizer_startsNotPrepared() async throws {
    let directory = try makeTempModelDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try makePlausibleModelFiles(in: directory)

    let manager = ModelManager(
      modelDirectory: directory,
      makeTranscriber: { _, _, _ in MockTranscriber() }
    )

    await manager.waitForInitialModelDiscoveryForTesting()
    XCTAssertEqual(manager.state, .notPrepared)
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
      makeTranscriber: { _, _, _ in
        MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil)))
      }
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
      try FileManager.default.createDirectory(
        at: componentDirectory, withIntermediateDirectories: true)
      // A torn download's leftover: a tiny placeholder, no `model.mil`.
      FileManager.default.createFile(
        atPath: componentDirectory.appendingPathComponent("coremldata.bin").path,
        contents: Data(repeating: 0, count: 329)
      )
    }

    let manager = ModelManager(
      modelDirectory: directory,
      makeTranscriber: { _, _, _ in
        MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil)))
      }
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
      try FileManager.default.createDirectory(
        at: componentDirectory, withIntermediateDirectories: true)
      FileManager.default.createFile(
        atPath: componentDirectory.appendingPathComponent("model.mil").path,
        contents: Data(repeating: 0, count: 64)
      )
    }

    let manager = ModelManager(
      modelDirectory: directory,
      makeTranscriber: { _, _, _ in
        MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil)))
      }
    )

    XCTAssertEqual(manager.state, .notPrepared)
  }

  /// Runtime loading is offline-only. A corrupt local model is removed and
  /// surfaced for explicit reinstall; it is never silently re-downloaded by
  /// a pre-warm/dictation path.
  func test_ensureLoaded_whenExistingLocalModelFails_doesNotRetryOrDownload() async throws {
    let directory = try makeTempModelDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try makePlausibleModelFiles(in: directory)
    try makeTokenizerFile(in: directory)

    var attempt = 0
    let manager = ModelManager(
      modelDirectory: directory,
      makeTranscriber: { _, _, _ in
        attempt += 1
        throw TranscribingError.underlying("corrupt model.mil")
      }
    )
    await manager.waitForInitialModelDiscoveryForTesting()
    XCTAssertEqual(
      manager.state, .unloaded, "starts detected as verified, exactly like the real regression")

    do {
      _ = try await manager.ensureLoaded()
      XCTFail("corrupt local model must require explicit reinstall")
    } catch ModelError.verificationFailed {
      // expected
    }

    XCTAssertEqual(manager.state, .failed(.verificationFailed))
    XCTAssertEqual(
      attempt, 1, "offline runtime must not retry a local compile as a network install")
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("MelSpectrogram.mlmodelc").path),
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
      try FileManager.default.createDirectory(
        at: componentDirectory, withIntermediateDirectories: true)
      let modelMilPath = componentDirectory.appendingPathComponent("model.mil").path
      FileManager.default.createFile(atPath: modelMilPath, contents: nil)
      let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: modelMilPath))
      try handle.truncate(atOffset: UInt64(perComponentBytes))
      try handle.close()
    }
  }

  /// Completes the offline fixture with every file WhisperKit's tokenizer
  /// loader consumes. A model-only or partial tokenizer directory must be
  /// rejected before the library can fall through to its Hub downloader.
  private func makeTokenizerFile(in directory: URL) throws {
    let tokenizerDirectory = ModelManager.tokenizerDirectory(in: directory)
      .appendingPathComponent(ModelCatalog.tokenizerRepoPath, isDirectory: true)
    try FileManager.default.createDirectory(
      at: tokenizerDirectory, withIntermediateDirectories: true)
    for name in ["tokenizer.json", "tokenizer_config.json", "config.json"] {
      let url = tokenizerDirectory.appendingPathComponent(name)
      XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data("{}".utf8)))
    }
  }

  // MARK: - Timer behavior

  /// `AT-026` (fires) and the cancellation half of `L-010` ("новая
  /// запись/импорт отменяет таймер"). Both use the production sleep and
  /// cancellation path with a 20 ms test minute.
  func test_unloadTimer_firesAfterOneMinute_unlessCancelledByNewTask() async throws {
    let firingManager = makeManager(unloadNanosecondsPerMinute: 20_000_000)
    _ = try await firingManager.installModel()
    firingManager.endTask(unloadMinutes: 1)

    let cancellingManager = makeManager(unloadNanosecondsPerMinute: 20_000_000)
    _ = try await cancellingManager.installModel()
    cancellingManager.endTask(unloadMinutes: 1)
    // A new recording/import starts right away: must cancel the pending
    // unload timer (`L-010`).
    cancellingManager.beginTask()

    try await Task.sleep(nanoseconds: 50_000_000)

    XCTAssertEqual(
      firingManager.state, .unloaded, "AT-026: timer must have unloaded the model after 1 minute.")
    XCTAssertEqual(
      cancellingManager.state, .ready,
      "L-010: beginTask() must have cancelled the pending unload timer."
    )
  }
}
