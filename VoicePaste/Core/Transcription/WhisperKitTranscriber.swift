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

/// Plain-value decoding decision for a `TranscriptionLanguage`, kept free of
/// any WhisperKit types so it can be unit-tested without linking the
/// WhisperKit package (`L-005`, `AT-095`).
public struct WhisperDecodingPlan: Equatable, Sendable {
    public let languageCode: String?
    public let detectLanguage: Bool
    public let usePrefillPrompt: Bool
    public let isTranslate: Bool

    public init(languageCode: String?, detectLanguage: Bool, usePrefillPrompt: Bool, isTranslate: Bool) {
        self.languageCode = languageCode
        self.detectLanguage = detectLanguage
        self.usePrefillPrompt = usePrefillPrompt
        self.isTranslate = isTranslate
    }
}

public struct WhisperKitTranscriber: Transcribing {
    /// `L-005`/`AT-095`: the decoding task is always transcription, never
    /// translation; in `.auto` the language is left unset with detection
    /// enabled, while `.ru`/`.en` force their language explicitly.
    public static func decodingPlan(for language: TranscriptionLanguage) -> WhisperDecodingPlan {
        switch language {
        case .auto:
            return WhisperDecodingPlan(
                languageCode: nil,
                detectLanguage: true,
                usePrefillPrompt: true,
                isTranslate: false
            )
        case .ru:
            return WhisperDecodingPlan(
                languageCode: "ru",
                detectLanguage: false,
                usePrefillPrompt: true,
                isTranslate: false
            )
        case .en:
            return WhisperDecodingPlan(
                languageCode: "en",
                detectLanguage: false,
                usePrefillPrompt: true,
                isTranslate: false
            )
        }
    }

#if canImport(WhisperKit)
    private let pipe: WhisperKit

    /// - Parameter downloadProgress: forwarded `Progress.fractionCompleted`
    ///   (`0...1`) updates for the first-run 626 MB download (`UI-002`,
    ///   `US-001`, `AT-086`, `L-010`). WhisperKit's multi-file download
    ///   reports `completedUnitCount`/`totalUnitCount` in *file counts*, not
    ///   bytes — forwarding those raw counters produces "0 из 0 МБ" and a
    ///   jumpy ETA. `fractionCompleted` is the one value `Foundation.Progress`
    ///   keeps consistent across a multi-file aggregate (it accounts for
    ///   child-progress weighting internally), so `ModelManager` derives all
    ///   displayed bytes/speed/ETA from this single reliable fraction times
    ///   the advertised catalog size instead. Never called on the
    ///   already-on-disk branch (no network involved).
    public init(
        modelDirectory: URL,
        endpoint: String = ModelCatalog.downloadEndpoint,
        downloadProgress: (@Sendable (Double) -> Void)? = nil
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
            // fetch the tokenizer/config over the network — route that
            // through the selected endpoint (`AT-093`) so it isn't slow from
            // China when the mirror is chosen.
            let config = WhisperKitConfig(
                model: ModelCatalog.modelID,
                modelEndpoint: endpoint,
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
                endpoint: endpoint,
                progressCallback: { progress in
                    downloadProgress?(progress.fractionCompleted)
                }
            )
            let config = WhisperKitConfig(
                model: ModelCatalog.modelID,
                modelEndpoint: endpoint,
                modelFolder: downloadedFolder.path,
                load: true,
                download: false
            )
            pipe = try await WhisperKit(config)
        }
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        guard !request.samples.isEmpty else { throw TranscribingError.emptyAudio }
        // `L-005`/`AT-095`: task is always transcription; `.auto` enables
        // language auto-detection instead of leaving it off by default.
        let plan = Self.decodingPlan(for: request.language)
        // WhisperKit's no-speech score is unavailable in the current CoreML
        // decoder implementation, so suppress blank starts here and apply a
        // timestamp + signal based terminal-silence guard below.
        let options = DecodingOptions(
            task: .transcribe,
            language: plan.languageCode,
            usePrefillPrompt: plan.usePrefillPrompt,
            detectLanguage: plan.detectLanguage,
            suppressBlank: true
        )
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
            detectedLanguage: plan.languageCode ?? results.first?.language
        )
    }
#else
    public init(
        modelDirectory: URL,
        endpoint: String = ModelCatalog.downloadEndpoint,
        downloadProgress: (@Sendable (Double) -> Void)? = nil
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
