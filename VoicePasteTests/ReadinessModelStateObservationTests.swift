import Combine
import XCTest
@testable import VoicePaste

/// Regression guard for the defect behind "первая расшифровка работает,
/// вторая — «Загрузка модели…»".
///
/// `ReadinessCoordinator` observes `ModelManager.$state`. A `@Published`
/// projected publisher emits in `willSet`: while subscribers run, the property
/// still holds the OLD value. The coordinator used to ignore the delivered
/// value and re-read `modelManager.state`, so it saw every transition one step
/// late. The final transition of a load is `verifying → ready`, which left
/// readiness computed from `.verifying` — `.downloadingModel` — with no further
/// emission to correct it. Readiness stayed stuck there until something called
/// `refresh()` directly (re-activating the app), which is exactly why clicking
/// through onboarding "fixed" it every time.
///
/// The observed log, verbatim:
///
///     model.state     preparing→verifying
///     readiness.state ready→downloadingModel
///     model.state     verifying→ready          ← nothing recomputed readiness
///     readiness.state downloadingModel→ready   ← 21 s later, on app activation
@MainActor
final class ReadinessModelStateObservationTests: XCTestCase {

    /// Pins the Combine semantics the bug rested on. If this ever starts
    /// failing, `@Published` changed and the comment above needs revisiting —
    /// but the coordinator stays correct either way, because it no longer
    /// re-reads the property.
    func test_publishedProjectedValue_emitsBeforeThePropertyIsUpdated() async throws {
        let manager = ModelManager(
            modelDirectory: FileManager.default.temporaryDirectory,
            makeTranscriber: { _, _, _ in
                MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil)))
            }
        )
        var propertyValuesSeenInsideSink: [String] = []
        var deliveredValues: [String] = []
        let cancellable = manager.$state.dropFirst().sink { delivered in
            deliveredValues.append(ModelManager.describe(delivered))
            propertyValuesSeenInsideSink.append(ModelManager.describe(manager.state))
        }
        defer { cancellable.cancel() }

        _ = try await manager.installModel()

        XCTAssertEqual(deliveredValues.last, "ready", "the publisher does deliver the new value")
        XCTAssertNotEqual(
            propertyValuesSeenInsideSink.last,
            "ready",
            "the property is still stale inside the sink — re-reading it is the bug"
        )
    }

    /// The coordinator must end at `.ready` after a load completes, without
    /// anybody calling `refresh()` afterwards. Requires both real permissions,
    /// since readiness short-circuits on them before it ever looks at the
    /// model; skipped rather than failed where TCC isn't granted to the test
    /// host, matching how this suite handles other environment-dependent
    /// fixtures.
    func test_afterLoadCompletes_readinessSettlesOnReady_withoutAnExtraRefresh() async throws {
        let manager = ModelManager(
            modelDirectory: FileManager.default.temporaryDirectory,
            makeTranscriber: { _, _, _ in
                MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil)))
            }
        )
        let coordinator = ReadinessCoordinator(modelManager: manager)
        try XCTSkipUnless(
            coordinator.state == .ready || coordinator.state == .needsModel,
            "test host lacks Microphone/Accessibility grants; readiness never reaches the model branch"
        )

        _ = try await manager.installModel()
        // One turn for the sink to run. No `refresh()` — that is the point.
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(manager.state, .ready)
        XCTAssertEqual(
            coordinator.state,
            .ready,
            "readiness must follow the model to .ready on its own, not stay on .downloadingModel"
        )
    }

    /// A local warm-up passes through `.verifying` without ever having been a
    /// download. Readiness must not announce "Загрузка модели…" for it — a
    /// hotkey press during that window joins the in-flight load instead of
    /// being refused.
    func test_verifyingAfterLocalWarmUp_isNotReportedAsDownloading() async throws {
        // A model already on disk — the whole point of this case. Without it
        // the loader legitimately reports `.downloading`.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadinessWarmUp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.makePlausibleModelFiles(in: directory)
        try Self.makeTokenizerFile(in: directory)

        let manager = ModelManager(
            modelDirectory: directory,
            makeTranscriber: { _, _, _ in
                MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil)))
            }
        )
        await manager.waitForInitialModelDiscoveryForTesting()
        let coordinator = ReadinessCoordinator(modelManager: manager)
        try XCTSkipUnless(
            coordinator.state == .ready || coordinator.state == .needsModel,
            "test host lacks Microphone/Accessibility grants; readiness never reaches the model branch"
        )

        var observed: [String] = []
        let cancellable = coordinator.$state.sink { observed.append(ReadinessCoordinator.describe($0)) }
        defer { cancellable.cancel() }

        _ = try await manager.ensureLoaded()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(
            observed.contains("downloadingModel"),
            "nothing was downloaded — readiness must never have claimed otherwise"
        )
    }

    /// Mirrors `ModelManagerTests`: files large and complete enough that
    /// `LocalModelDetection` accepts them as a real downloaded model.
    private static func makePlausibleModelFiles(in directory: URL) throws {
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

    private static func makeTokenizerFile(in directory: URL) throws {
        let tokenizerDirectory = ModelManager.tokenizerDirectory(in: directory)
            .appendingPathComponent(ModelCatalog.tokenizerRepoPath, isDirectory: true)
        try FileManager.default.createDirectory(at: tokenizerDirectory, withIntermediateDirectories: true)
        for name in ["tokenizer.json", "tokenizer_config.json", "config.json"] {
            try Data("{}".utf8).write(to: tokenizerDirectory.appendingPathComponent(name))
        }
    }
}
