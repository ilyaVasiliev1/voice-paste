import Dispatch
import Foundation

/// Owns the WhisperKit model lifecycle (`L-010`, `L-011`, `API-local-model`).
///
/// - First transcription lazily loads/compiles the model (`ensureLoaded()`).
/// - After the last active task, an unload timer starts using
///   `DM-001.modelUnloadMinutes` (1–60, default 10; `0` keeps it warm).
/// - A new recording/import cancels the pending timer (`beginTask()`).
/// - `unloadNow()` is called on app quit and from Settings "Выгрузить сейчас".
@MainActor
public final class ModelManager: ObservableObject {
    @Published public private(set) var state: ModelState = .notPrepared

    private var transcriber: Transcribing?
    private var unloadTask: Task<Void, Never>?
    private let modelDirectory: URL
    private let makeTranscriber: (URL, String, @escaping @Sendable (Double) -> Void) async throws -> Transcribing
    /// Reads the live download-source setting at the moment a download
    /// starts (`AT-093`, `L-010`) — a change mid-session takes effect on the
    /// *next* `load()`, not retroactively. Defaults to the mirror when no
    /// provider is supplied.
    private let downloadEndpointProvider: @MainActor () -> String

    public init(
        modelDirectory: URL,
        makeTranscriber: @escaping (URL, String, @escaping @Sendable (Double) -> Void) async throws -> Transcribing = ModelManager.defaultTranscriberFactory,
        downloadEndpointProvider: @escaping @MainActor () -> String = { ModelCatalog.downloadEndpoint }
    ) {
        self.modelDirectory = modelDirectory
        self.makeTranscriber = makeTranscriber
        self.downloadEndpointProvider = downloadEndpointProvider
        // `L-001`/`AT-004`: a previous run may have already downloaded and
        // compiled the model into `modelDirectory`. Detect it up front so a
        // restart doesn't ask for a 626 MB re-download — `.unloaded` means
        // "verified on disk, not resident in memory yet", exactly the state
        // `ensureLoaded()` already knows how to lazily reload from.
        if Self.hasVerifiedLocalModel(in: modelDirectory) {
            self.state = .unloaded
        }
    }

    /// Detects an already-downloaded, verified local model without importing
    /// WhisperKit (this type stays buildable even where the WhisperKit
    /// package can't resolve, see `WhisperKitTranscriber`'s isolation
    /// comment). Delegates to `LocalModelDetection`, the single shared
    /// criterion also used by `WhisperKitTranscriber`'s actual load path —
    /// so a positive result here is guaranteed to mean `ensureLoaded()` will
    /// find everything it needs without re-downloading (`AT-004`), even
    /// though WhisperKit nests the model a few levels below `modelDirectory`
    /// rather than placing it flatly at the root.
    private static func hasVerifiedLocalModel(in directory: URL) -> Bool {
        LocalModelDetection.discoverModelFolder(in: directory) != nil
    }

    public var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    /// `EC-007`: refuses to start a download when free space is insufficient.
    public func checkStorage() -> ModelError? {
        guard let values = try? modelDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        if available < ModelCatalog.approximateSizeBytes {
            return .insufficientStorage(requiredBytes: ModelCatalog.approximateSizeBytes, availableBytes: available)
        }
        return nil
    }

    /// Loads/compiles the model if needed and cancels any pending unload timer.
    /// Called before every dictation/import transcription (`L-010`).
    ///
    /// If a local model folder was already on disk and passed
    /// `LocalModelDetection`'s check, but the actual load still fails (e.g.
    /// WhisperKit's "Failed to parse ML Program … model.mil cannot be read"
    /// on a subtly-corrupt file that the plausible-size heuristic didn't
    /// catch), the on-disk folder is treated as invalid: it's deleted and a
    /// single clean re-download is attempted automatically, rather than
    /// leaving the app stuck in `.failed`/"ошибка готовности" until the user
    /// manually clears `~/Library/Application Support`.
    public func ensureLoaded() async throws -> Transcribing {
        beginTask()
        if let transcriber, isReady {
            return transcriber
        }
        if let storageError = checkStorage(), state == .notPrepared {
            state = .failed(storageError)
            throw storageError
        }
        let hadExistingLocalModel = Self.hasVerifiedLocalModel(in: modelDirectory)
        do {
            return try await loadWithAutoRetry()
        } catch {
            Task { await DiagnosticLog.shared.log("model.load.failed", detail: String(describing: error)) }
            guard hadExistingLocalModel else {
                state = .failed(.downloadFailed)
                throw error
            }
            // The folder that `LocalModelDetection` trusted turned out to be
            // unloadable — most likely corrupt/truncated rather than merely
            // "not yet downloaded". Wipe it so the next attempt can't find it
            // and falls through to `WhisperKitTranscriber`'s clean download
            // branch instead of retrying the same broken files.
            Task { await DiagnosticLog.shared.log("model.local.invalid") }
            removeModelDirectoryContents()
            do {
                Task { await DiagnosticLog.shared.log("model.redownload") }
                return try await loadWithAutoRetry()
            } catch {
                state = .failed(.downloadFailed)
                Task { await DiagnosticLog.shared.log("model.load.failed", detail: String(describing: error)) }
                throw error
            }
        }
    }

    /// First-attempt resilience for a transient network hiccup (observed in
    /// practice against the `hf-mirror.com` mirror from mainland China):
    /// retries `load()` up to `Self.maxAutoDownloadRetries` times on *any*
    /// error before surfacing `.failed` to the caller. Deliberately doesn't
    /// try to classify the error (e.g. sniff `URLError` codes) — HF Hub's
    /// download is resumable, so retrying blindly on any failure is both
    /// simpler and safe: a retry after a transient disconnect resumes the
    /// already-downloaded parts, and a retry after a genuinely fatal error
    /// (e.g. disk full) just fails again and is bounded by the retry cap, so
    /// this stays deterministic and testable. This is a distinct, earlier
    /// layer from the wipe+redownload fallback in `ensureLoaded()` — that one
    /// handles a corrupt *existing* local folder; this one handles a flaky
    /// *first* download attempt and never touches the filesystem itself.
    private func loadWithAutoRetry() async throws -> Transcribing {
        var lastError: Error?
        for attempt in 0...Self.maxAutoDownloadRetries {
            do {
                return try await load()
            } catch {
                lastError = error
                guard attempt < Self.maxAutoDownloadRetries else { break }
                Task { await DiagnosticLog.shared.log("model.load.retry", detail: "attempt \(attempt + 1)") }
                try? await Task.sleep(nanoseconds: Self.autoRetryPauseNanos)
            }
        }
        throw lastError ?? ModelError.downloadFailed
    }

    /// Bounds the blind auto-retry in `loadWithAutoRetry()`: a network blip
    /// gets at most this many extra attempts before the honest failed-state
    /// (`_tests.md` AT-086) is shown with a manual "Повторить".
    private static let maxAutoDownloadRetries = 2
    /// Short pause between auto-retries — long enough to let a transient
    /// disconnect clear, short enough that the user isn't staring at a
    /// frozen screen before either success or the next attempt's progress.
    private static let autoRetryPauseNanos: UInt64 = 1_500_000_000

    private func load() async throws -> Transcribing {
        resetDownloadProgressTracking()
        state = .downloading(ModelDownloadProgress(
            completedBytes: 0,
            totalBytes: ModelCatalog.approximateSizeBytes,
            fraction: 0
        ))
        Task { await DiagnosticLog.shared.log("model.load.start") }
        let endpoint = downloadEndpointProvider()
        let engine = try await makeTranscriber(modelDirectory, endpoint) { [weak self] fraction in
            // WhisperKit's `progressCallback` may fire from a background
            // download-session thread; hop onto the main actor before
            // touching `@Published state` or the milestone tracker below
            // (Swift 6 strict concurrency — no direct mutation here).
            Task { @MainActor in
                self?.handleDownloadProgress(fraction: fraction)
            }
        }
        state = .verifying
        transcriber = engine
        state = .ready
        Task { await DiagnosticLog.shared.log("model.load.success") }
        return engine
    }

    /// Removes everything under `modelDirectory` (recreating the empty
    /// directory) so a corrupt/partial model can't be mistaken for a valid
    /// one on the next attempt. `modelDirectory` is exclusively owned by
    /// this app for model storage (see `App`'s setup), so this is safe.
    private func removeModelDirectoryContents() {
        try? FileManager.default.removeItem(at: modelDirectory)
        try? FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
    }

    /// Milestone tracker for download progress logging (`_standards.md`
    /// observability: every ~10%, never per-tick spam). Main-actor isolated
    /// so it's safe to update from the (possibly background-thread) download
    /// progress callback via a `Task { @MainActor in ... }` hop.
    private var lastLoggedDownloadDecile = -1

    // `AT-086`/`L-010` honest-progress tracking. All timestamps use
    // `DispatchTime.now().uptimeNanoseconds` — a monotonic clock that never
    // jumps with wall-clock/NTP adjustments — because speed is defined as a
    // derivative of *downloaded bytes* over *elapsed monotonic time*, not
    // over `Date()`.
    private var lastByteSample: (bytes: Int64, uptimeNanos: UInt64)?
    private var firstByteSampleNanos: UInt64?
    private var smoothedSpeedBytesPerSecond: Double?
    private var speedSampleCount = 0
    private var lastUIUpdateNanos: UInt64?

    /// Exponential-moving-average weight for the speed smoothing: recent
    /// samples matter more, but a single noisy tick can't swing the shown
    /// speed/ETA wildly.
    private static let speedSmoothingAlpha = 0.3
    /// UI updates are throttled to this interval (`4 Hz`, mirrors `AT-062`'s
    /// import-progress throttle).
    private static let uiThrottleSeconds = 0.25
    /// ETA only appears once at least this many byte-delta samples *and*
    /// this much wall-clock-free elapsed time have gone into the smoothed
    /// speed — otherwise the very first, noisiest samples would produce a
    /// wildly wrong estimate. Below this bar the UI shows "Считаем время…".
    private static let minSpeedSamplesForETA = 3
    private static let minElapsedSecondsForETA = 1.0

    private func resetDownloadProgressTracking() {
        lastByteSample = nil
        firstByteSampleNanos = nil
        smoothedSpeedBytesPerSecond = nil
        speedSampleCount = 0
        lastUIUpdateNanos = nil
        lastLoggedDownloadDecile = -1
        maxPublishedFraction = 0
    }

    /// Highest `fraction` published so far this attempt (`L-010`: "Прогресс
    /// монотонно растёт"). WhisperKit's underlying `Progress` aggregate can
    /// jitter downward for an instant (child-progress reweighting, a chunk
    /// resume) even though nothing is actually being un-downloaded; the
    /// *shown* fraction must never follow it backwards. Reset on every fresh
    /// `load()` attempt so a retry after a failure doesn't inherit the
    /// previous attempt's high-water mark.
    private var maxPublishedFraction: Double = 0

    /// Derives all displayed download progress from the single reliable
    /// `Progress.fractionCompleted` value (`L-010`, `AT-086`, `UI-002`).
    /// WhisperKit's own `completedUnitCount`/`totalUnitCount` count *files*,
    /// not bytes, in a multi-file download — forwarding those raw counters
    /// is what previously produced "0 из 0 МБ" and a jumpy ETA. `fraction`
    /// doesn't have that problem, so `totalBytes` is always the advertised
    /// catalog constant (626 MB) and `completedBytes` is `fraction ×
    /// totalBytes`; speed/ETA are then a derivative of *that derived byte
    /// count* over monotonic time, exactly as before.
    private func handleDownloadProgress(fraction rawFraction: Double) {
        guard case .downloading = state else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let totalBytes = ModelCatalog.approximateSizeBytes

        // Capped below 100%: the jump to "done" only happens via the
        // `.verifying` transition in `load()`, never here.
        let cappedFraction = min(max(rawFraction, 0), 0.999)
        // Monotonic (`L-010`): never publish a fraction lower than the
        // highest one already shown this attempt, even if the raw signal
        // jittered downward.
        let fraction = max(cappedFraction, maxPublishedFraction)
        maxPublishedFraction = fraction
        let completedBytes = Int64(fraction * Double(totalBytes))

        if let last = lastByteSample {
            let elapsedSeconds = Double(now - last.uptimeNanos) / 1_000_000_000
            let deltaBytes = completedBytes - last.bytes
            if elapsedSeconds > 0, deltaBytes >= 0 {
                let instantSpeed = Double(deltaBytes) / elapsedSeconds
                smoothedSpeedBytesPerSecond = smoothedSpeedBytesPerSecond.map {
                    $0 + Self.speedSmoothingAlpha * (instantSpeed - $0)
                } ?? instantSpeed
                speedSampleCount += 1
            }
        } else {
            firstByteSampleNanos = now
        }
        lastByteSample = (completedBytes, now)

        // Throttle screen updates to ≤4 Hz (`AT-086`); always let the very
        // first sample through so the step doesn't sit frozen at 0%.
        if let lastUI = lastUIUpdateNanos,
           Double(now - lastUI) / 1_000_000_000 < Self.uiThrottleSeconds {
            return
        }
        lastUIUpdateNanos = now

        let hasEnoughSpeedSignal: Bool = {
            guard speedSampleCount >= Self.minSpeedSamplesForETA,
                  let firstNanos = firstByteSampleNanos,
                  let speed = smoothedSpeedBytesPerSecond, speed > 0 else { return false }
            return Double(now - firstNanos) / 1_000_000_000 >= Self.minElapsedSecondsForETA
        }()
        let speed = hasEnoughSpeedSignal ? smoothedSpeedBytesPerSecond : nil
        let eta: Double? = speed.map { max(0, Double(totalBytes - completedBytes)) / $0 }

        state = .downloading(ModelDownloadProgress(
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            fraction: fraction,
            speedBytesPerSecond: speed,
            etaSeconds: eta
        ))

        let decile = Int(fraction * 10)
        if decile != lastLoggedDownloadDecile {
            lastLoggedDownloadDecile = decile
            Task { await DiagnosticLog.shared.log("model.load.progress", detail: "\(decile * 10)%") }
        }
    }

    /// A recording/import started: cancel any pending unload (`L-010`).
    public func beginTask() {
        unloadTask?.cancel()
        unloadTask = nil
    }

    /// A recording/import finished: (re)start the unload timer per settings.
    public func endTask(unloadMinutes: Int) {
        unloadTask?.cancel()
        guard unloadMinutes > 0 else { return }
        let nanoseconds = UInt64(unloadMinutes) * 60 * 1_000_000_000
        unloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.unloadNow()
        }
    }

    /// `AT-026`/quit: releases the loaded model immediately.
    public func unloadNow() {
        unloadTask?.cancel()
        unloadTask = nil
        transcriber = nil
        if case .ready = state {
            state = .unloaded
            Task { await DiagnosticLog.shared.log("model.unload") }
        }
    }

    public static func defaultTranscriberFactory(
        modelDirectory: URL,
        endpoint: String,
        downloadProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Transcribing {
        try await WhisperKitTranscriber(modelDirectory: modelDirectory, endpoint: endpoint, downloadProgress: downloadProgress)
    }
}
