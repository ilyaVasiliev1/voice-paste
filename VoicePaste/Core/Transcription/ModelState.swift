import Foundation

/// `API-local-model` result type (`INV-004`, `L-010`, `L-011`).
public enum ModelState: Equatable, Sendable {
    case notPrepared
    case downloading(ModelDownloadProgress)
    case verifying
    case ready
    case unloaded
    case failed(ModelError)
}

/// Byte-level detail behind `.downloading` (`AT-086`, `L-010`, `UI-002`).
///
/// `completedBytes`/`totalBytes` are *derived*, not read from the loader's
/// own counters: WhisperKit's multi-file download reports progress in file
/// counts, not bytes, so `totalBytes` is always the advertised catalog
/// constant (626 MB) and `completedBytes` is `fraction × totalBytes`, where
/// `fraction` mirrors `Foundation.Progress.fractionCompleted` — the one
/// value that stays consistent across a multi-file aggregate. Never a
/// separate synthetic timer. `speedBytesPerSecond` is a smoothed derivative
/// of those derived bytes over monotonic time (never wall clock), and
/// `etaSeconds` is only populated once that smoothed speed is a trustworthy
/// signal; both are `nil` until then, so the UI can show "Считаем время…"
/// honestly instead of guessing.
public struct ModelDownloadProgress: Equatable, Sendable {
    public let completedBytes: Int64
    public let totalBytes: Int64
    /// Capped strictly below `1.0` for as long as the state is `.downloading`
    /// — the jump to "done" only happens through the `.verifying` transition,
    /// never through this fraction reaching `1`.
    public let fraction: Double
    public let speedBytesPerSecond: Double?
    public let etaSeconds: Double?

    public init(
        completedBytes: Int64,
        totalBytes: Int64,
        fraction: Double,
        speedBytesPerSecond: Double? = nil,
        etaSeconds: Double? = nil
    ) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.fraction = fraction
        self.speedBytesPerSecond = speedBytesPerSecond
        self.etaSeconds = etaSeconds
    }
}

public enum ModelError: Error, Equatable, Sendable {
    case downloadFailed
    case verificationFailed
    case insufficientStorage(requiredBytes: Int64, availableBytes: Int64)
}

/// v1 ships exactly one open WhisperKit model (`INV-004`).
/// Immutable catalog data is read by the background model loader and must not
/// force that loader back onto the SwiftUI main actor.
nonisolated public enum ModelCatalog {
    public static let modelID = "large-v3-v20240930_626MB"
    /// On-disk folder name WhisperKit unpacks the model variant into (the Hub
    /// prefixes the repo owner). Used to verify the GitHub archive extracted a
    /// complete model, not a truncated one.
    public static let modelFolderName = "openai_whisper-large-v3-v20240930_626MB"
    /// Advertised download size, used for the `EC-007` free-space check and
    /// for the Settings "Модель" size label.
    public static let approximateSizeBytes: Int64 = 626 * 1024 * 1024
    /// Hugging Face endpoint WhisperKit downloads the model *and* tokenizer/
    /// config from. Defaults to the `hf-mirror.com` mirror because the primary
    /// `huggingface.co` host is heavily throttled from mainland China (where
    /// this app is used), turning the one-time 626 MB fetch into hours; the
    /// mirror serves the same `argmaxinc/whisperkit-coreml` files at usable
    /// speed. Both `WhisperKit.download(endpoint:)` and
    /// `WhisperKitConfig(modelEndpoint:)` honour this. Swap back to
    /// `https://huggingface.co` if the mirror is ever unavailable.
    public static let downloadEndpoint = "https://hf-mirror.com"

    /// Direct GitHub-Release download for the `.github` source (`L-010`). Used
    /// from mainland China where both HuggingFace hosts are unreachable but
    /// GitHub is. The model is an open, static artifact (Whisper, OpenAI)
    /// re-hosted on the project's own release, so this is a plain HTTPS `.zip`
    /// fetch that bypasses the Hub — and, unlike WhisperKit's multi-file Hub
    /// download, it resumes across retries.
    public static let githubModelArchiveURL = URL(
        string: "https://github.com/ilyaVasiliev1/voice-paste/releases/download/model-large-v3/whisperkit-large-v3.zip"
    )!
    /// The tokenizer WhisperKit otherwise fetches from HuggingFace separately
    /// from the model (`openai/whisper-large-v3`). Bundling it lets the
    /// `.github` source load fully offline; ~640 KB.
    public static let githubTokenizerArchiveURL = URL(
        string: "https://github.com/ilyaVasiliev1/voice-paste/releases/download/model-large-v3/whisper-large-v3-tokenizer.zip"
    )!
    /// The single tokenizer repo id WhisperKit resolves for this model, used to
    /// verify the tokenizer archive extracted correctly.
    public static let tokenizerRepoPath = "models/openai/whisper-large-v3"
}

/// User-selectable Hugging Face host for model/tokenizer/config downloads
/// (`AT-093`, `L-010`). Persisted in `DM-001` via `AppSettings.modelDownloadSource`;
/// applies to the *next* download only — an already-verified local model
/// (`ModelState.unloaded`/`.ready`) is never re-fetched on a source change.
public enum ModelDownloadSource: String, CaseIterable, Sendable {
    /// Direct download from the project's GitHub Release. The only source that
    /// works from mainland China (HuggingFace is blocked there); fetches the
    /// model + tokenizer as `.zip` archives, fully offline afterwards.
    case github
    case mirror
    case official

    /// HuggingFace host WhisperKit downloads from for the `.mirror`/`.official`
    /// sources. `.github` doesn't use an HF endpoint — it lays the model down
    /// directly — but returns the official host as a harmless fallback for any
    /// tokenizer/config lookup that isn't already satisfied locally.
    public var endpoint: String {
        switch self {
        case .github: return "https://huggingface.co"
        case .mirror: return "https://hf-mirror.com"
        case .official: return "https://huggingface.co"
        }
    }

    /// `true` when the model is fetched as a direct archive (GitHub) rather
    /// than through WhisperKit's HuggingFace-Hub download.
    public var usesDirectArchive: Bool { self == .github }
}
