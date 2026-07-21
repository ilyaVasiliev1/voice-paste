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
/// Percent and "N из 626 МБ" are read directly from `completedBytes`/
/// `totalBytes` — the same counters `Foundation.Progress` reports for the
/// download — never from a separate synthetic timer. `speedBytesPerSecond`
/// is a smoothed derivative of those bytes over monotonic time (never wall
/// clock), and `etaSeconds` is only populated once that smoothed speed is a
/// trustworthy signal; both are `nil` until then, so the UI can show
/// "Считаем время…" honestly instead of guessing.
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
public enum ModelCatalog {
    public static let modelID = "large-v3-v20240930_626MB"
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
}
