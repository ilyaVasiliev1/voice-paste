import Foundation

#if canImport(WhisperKit)
import WhisperKit
#endif

/// Concrete WhisperKit-backed transcriber (`DEP-006`, `INV-004`).
///
/// Kept isolated in this single file: if the WhisperKit package cannot be
/// resolved in a given build environment, only this file's real
/// implementation is unavailable — the rest of the app keeps compiling
/// against the `Transcribing` protocol and unit tests run against
/// `MockTranscriber` instead.
public struct WhisperKitTranscriber: Transcribing {
#if canImport(WhisperKit)
    private let pipe: WhisperKit

    /// - Parameter downloadProgress: forwarded `(completedBytes, totalBytes)`
    ///   updates for the first-run 626 MB download (`UI-002`, `US-001`,
    ///   `AT-086`) — raw counters straight from `Foundation.Progress`, so
    ///   `ModelManager` can derive percent/speed/ETA itself rather than
    ///   receiving an already-collapsed fraction. Never called on the
    ///   already-on-disk branch (no network involved).
    public init(
        modelDirectory: URL,
        downloadProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws {
        // `L-010`/`AT-004`/`US-001`: WhisperKit's `setupModels` takes two
        // mutually exclusive branches (see `setupModels` in
        // `WhisperKit/Core/WhisperKit.swift`): if `modelFolder` is non-nil it
        // loads straight from that folder and the `download` branch below it
        // is never reached — so `modelFolder` must only be supplied once a
        // verified local model actually exists on disk. `download: true`
        // only takes effect when `modelFolder == nil`.
        //
        // WhisperKit's own download path (`WhisperKitConfig.downloadBase` /
        // the internal Hugging Face Hub cache, see `HubApi.localRepoLocation`
        // in `ArgmaxCore/External/Hub/HubApi.swift`) writes the model into
        // `<downloadBase>/models/argmaxinc/whisperkit-coreml/<variant>`, not
        // flatly into `downloadBase` itself — so a repeat launch has to
        // rediscover that nested folder rather than assume it sits directly
        // in `modelDirectory` (mirrors the official WhisperAX example app's
        // `fetchModels()`/`loadModel()` local-vs-download branching).
        if let existing = LocalModelDetection.discoverModelFolder(in: modelDirectory) {
            // Already downloaded and verified: load straight from disk, no
            // network involved (`AT-004` — "повторная загрузка не требуется").
            // `modelEndpoint`: even on the on-disk branch WhisperKit may still
            // fetch the tokenizer/config over the network — route that through
            // the mirror too (`ModelCatalog.downloadEndpoint`) so it isn't slow
            // from China.
            let config = WhisperKitConfig(
                model: ModelCatalog.modelID,
                modelEndpoint: ModelCatalog.downloadEndpoint,
                modelFolder: existing.path,
                download: false
            )
            pipe = try await WhisperKit(config)
        } else {
            // First run: no local model yet. `WhisperKit(config:)` itself has
            // no download-progress callback — its `download: true` branch
            // calls `WhisperKit.download(...)` internally with no way to
            // observe progress from the outside. So the download is driven
            // explicitly here via the public `WhisperKit.download(...)`
            // static (which *does* take a `progressCallback`), and only once
            // that finishes is the (now on-disk) model folder handed to
            // `WhisperKitConfig(modelFolder:download:false)` to load — this
            // is exactly the two-step flow the fix requires so
            // `ModelManager.state = .downloading(progress:)` moves instead of
            // sitting frozen at 0 for the whole 626 MB transfer.
            let downloadedFolder = try await WhisperKit.download(
                variant: ModelCatalog.modelID,
                downloadBase: modelDirectory,
                endpoint: ModelCatalog.downloadEndpoint,
                progressCallback: { progress in
                    downloadProgress?(progress.completedUnitCount, progress.totalUnitCount)
                }
            )
            let config = WhisperKitConfig(
                model: ModelCatalog.modelID,
                modelEndpoint: ModelCatalog.downloadEndpoint,
                modelFolder: downloadedFolder.path,
                load: true,
                download: false
            )
            pipe = try await WhisperKit(config)
        }
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        guard !request.samples.isEmpty else { throw TranscribingError.emptyAudio }
        let languageCode: String?
        switch request.language {
        case .auto: languageCode = nil
        case .ru: languageCode = "ru"
        case .en: languageCode = "en"
        }
        // WhisperKit's no-speech score is unavailable in the current CoreML
        // decoder implementation, so suppress blank starts here and apply a
        // timestamp + signal based terminal-silence guard below.
        let options = DecodingOptions(language: languageCode, suppressBlank: true)
        let samplesForInference = TrailingHallucinationFilter.trimmingLongTrailingSilence(
            from: request.samples
        )
        let results = try await pipe.transcribe(audioArray: samplesForInference, decodeOptions: options)
        let rawText = results.map(\.text).joined(separator: " ")
        let segments = results.flatMap(\.segments).map {
            TrailingHallucinationFilter.Segment(
                text: $0.text,
                startSeconds: Double($0.start)
            )
        }
        let text = TrailingHallucinationFilter.filtering(
            rawText: rawText,
            segments: segments,
            samples: samplesForInference
        )
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscribingError.emptyAudio
        }
        return TranscriptionResult(
            rawText: text,
            detectedLanguage: languageCode ?? results.first?.language
        )
    }
#else
    public init(
        modelDirectory: URL,
        downloadProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws {
        throw TranscribingError.underlying(
            "WhisperKit package is not resolvable in this build environment (see report tail)."
        )
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        throw TranscribingError.underlying(
            "WhisperKit package is not resolvable in this build environment (see report tail)."
        )
    }
#endif
}
