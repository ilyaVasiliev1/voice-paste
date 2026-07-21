import XCTest
@testable import VoicePaste

/// `AT-093`/`L-010` — endpoint mapping and end-to-end propagation from the
/// selected source down to the loader's factory call. Proof mode `auto`/
/// `integration`: no network, mock `Transcribing` factory that only
/// *records* which endpoint it was asked to use.
@MainActor
final class ModelDownloadSourceTests: XCTestCase {

    // MARK: - Endpoint mapping

    func test_mirror_mapsToHfMirrorEndpoint() {
        XCTAssertEqual(ModelDownloadSource.mirror.endpoint, "https://hf-mirror.com")
    }

    func test_official_mapsToHuggingFaceEndpoint() {
        XCTAssertEqual(ModelDownloadSource.official.endpoint, "https://huggingface.co")
    }

    func test_catalogDefaultEndpoint_matchesMirror() {
        // `ModelCatalog.downloadEndpoint` is the documented fallback for
        // "пользователь не менял настройку" (`L-010`) — it must stay in
        // lockstep with `.mirror.endpoint`.
        XCTAssertEqual(ModelCatalog.downloadEndpoint, ModelDownloadSource.mirror.endpoint)
    }

    // MARK: - Propagation: selected source actually reaches the loader

    /// The core `AT-093` claim: "Выбранный источник реально используется
    /// загрузчиком". A `downloadEndpointProvider` returning `.official`'s
    /// endpoint must result in the transcriber factory being invoked with
    /// exactly that URL — not silently falling back to the mirror.
    func test_ensureLoaded_withOfficialProvider_passesOfficialEndpointToFactory() async throws {
        var capturedEndpoint: String?
        let manager = ModelManager(
            modelDirectory: FileManager.default.temporaryDirectory,
            makeTranscriber: { _, endpoint, _ in
                capturedEndpoint = endpoint
                return MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil)))
            },
            downloadEndpointProvider: { ModelDownloadSource.official.endpoint }
        )

        _ = try await manager.ensureLoaded()

        XCTAssertEqual(capturedEndpoint, "https://huggingface.co")
    }

    /// Symmetric case: an explicit `.mirror` provider reaches the factory
    /// too, not just the implicit default — proves the plumbing is a real
    /// pass-through, not a hardcoded mirror constant.
    func test_ensureLoaded_withMirrorProvider_passesMirrorEndpointToFactory() async throws {
        var capturedEndpoint: String?
        let manager = ModelManager(
            modelDirectory: FileManager.default.temporaryDirectory,
            makeTranscriber: { _, endpoint, _ in
                capturedEndpoint = endpoint
                return MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil)))
            },
            downloadEndpointProvider: { ModelDownloadSource.mirror.endpoint }
        )

        _ = try await manager.ensureLoaded()

        XCTAssertEqual(capturedEndpoint, "https://hf-mirror.com")
    }

    /// `AT-093`/`L-010`: "по умолчанию — зеркало" at the loader boundary —
    /// omitting `downloadEndpointProvider` entirely (the real production
    /// default) must still resolve to the mirror URL, without any Settings
    /// object involved.
    func test_ensureLoaded_withDefaultProvider_passesMirrorEndpoint() async throws {
        var capturedEndpoint: String?
        let manager = ModelManager(
            modelDirectory: FileManager.default.temporaryDirectory,
            makeTranscriber: { _, endpoint, _ in
                capturedEndpoint = endpoint
                return MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil)))
            }
        )

        _ = try await manager.ensureLoaded()

        XCTAssertEqual(capturedEndpoint, "https://hf-mirror.com")
    }

    /// `L-010`: "Смена применяется к следующей загрузке" — a provider backed
    /// by a mutable box, switched *after* construction but *before* the
    /// first `ensureLoaded()` call, must be read live at load time, not
    /// captured once at `ModelManager.init`. This is the closest an `auto`
    /// test can get to "смена источника применяется к следующей загрузке"
    /// without a real second download (unloading and reloading the *same*
    /// verified model is explicitly out of scope per `L-010`: a source
    /// change never re-fetches an already-verified local model).
    func test_changingProviderValue_beforeFirstLoad_isReadLiveNotCapturedAtInit() async throws {
        final class SourceBox: @unchecked Sendable {
            var source: ModelDownloadSource = .mirror
        }
        let box = SourceBox()
        var capturedEndpoint: String?
        let manager = ModelManager(
            modelDirectory: FileManager.default.temporaryDirectory,
            makeTranscriber: { _, endpoint, _ in
                capturedEndpoint = endpoint
                return MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil)))
            },
            downloadEndpointProvider: { box.source.endpoint }
        )

        // Simulates the user changing the Settings picker after the app
        // (and its ModelManager) already started, before any download ran.
        box.source = .official

        _ = try await manager.ensureLoaded()

        XCTAssertEqual(capturedEndpoint, "https://huggingface.co")
    }
}
