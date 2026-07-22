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
    /// Startup model discovery walks the on-disk Core ML bundle and can touch
    /// hundreds of megabytes. Keep its task separate from UI state so app
    /// launch and permission/onboarding controls never wait for that walk.
    private var initialModelDiscoveryTask: Task<Bool, Never>?
    private var initialModelDiscoveryToken: UUID?
    private let modelDirectory: URL
    private let makeTranscriber: (URL, String, @escaping @Sendable (Double) -> Void) async throws -> Transcribing
    /// Reads the live download-source setting at the moment a download
    /// starts (`AT-093`, `L-010`) — a change mid-session takes effect on the
    /// *next* `load()`, not retroactively. Defaults to the mirror when no
    /// provider is supplied.
    private let downloadEndpointProvider: @MainActor () -> String
    /// Reads the live download-*source* at the moment a download starts. The
    /// `.github` source takes a completely different path (direct archive
    /// download) from `.mirror`/`.official` (WhisperKit Hub), so the source —
    /// not just its HF endpoint string — is needed here. Defaults to `.mirror`.
    private let downloadSourceProvider: @MainActor () -> ModelDownloadSource
    /// The in-flight GitHub archive download, kept so `cancelDownload()` can
    /// stop it (producing resume data) without cancelling the whole app.
    private var activeDownloader: GitHubModelDownloader?

    public init(
        modelDirectory: URL,
        makeTranscriber: @escaping (URL, String, @escaping @Sendable (Double) -> Void) async throws -> Transcribing = ModelManager.defaultTranscriberFactory,
        downloadEndpointProvider: @escaping @MainActor () -> String = { ModelCatalog.downloadEndpoint },
        downloadSourceProvider: @escaping @MainActor () -> ModelDownloadSource = { .mirror }
    ) {
        self.modelDirectory = modelDirectory
        self.makeTranscriber = makeTranscriber
        self.downloadEndpointProvider = downloadEndpointProvider
        self.downloadSourceProvider = downloadSourceProvider
        // `L-001`/`AT-004`: a previous run may have already downloaded and
        // compiled the model into `modelDirectory`. Detect it up front so a
        // restart doesn't ask for a 626 MB re-download — `.unloaded` means
        // "verified on disk, not resident in memory yet", exactly the state
        // `ensureLoaded()` already knows how to lazily reload from.
        let token = UUID()
        let discoveryTask = Task.detached(priority: .utility) {
            Self.hasVerifiedLocalModel(in: modelDirectory)
        }
        self.initialModelDiscoveryToken = token
        self.initialModelDiscoveryTask = discoveryTask
        Task { [weak self] in
            let hasLocalModel = await discoveryTask.value
            self?.completeInitialModelDiscovery(hasLocalModel, token: token)
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
    nonisolated private static func hasVerifiedLocalModel(in directory: URL) -> Bool {
        LocalModelDetection.discoverModelFolder(in: directory) != nil
    }

    /// Finishes the background startup check exactly once. A deletion or a
    /// load started before the check returns invalidates the old result, so a
    /// stale directory walk can never overwrite the current model state.
    private func completeInitialModelDiscovery(_ hasLocalModel: Bool, token: UUID) {
        guard initialModelDiscoveryToken == token else { return }
        initialModelDiscoveryTask = nil
        initialModelDiscoveryToken = nil
        guard hasLocalModel, transcriber == nil, state == .notPrepared else { return }
        state = .unloaded
    }

    /// `ensureLoaded()` waits for the already-running disk check rather than
    /// starting a competing walk. Awaiting yields the main actor; it does not
    /// block clicks, animations, or the menu bar.
    private func waitForInitialModelDiscovery() async {
        guard let task = initialModelDiscoveryTask,
              let token = initialModelDiscoveryToken else { return }
        let hasLocalModel = await task.value
        completeInitialModelDiscovery(hasLocalModel, token: token)
    }

    /// Test-only visibility into asynchronous startup discovery. Kept
    /// internal so product callers continue to use `ensureLoaded()`.
    func waitForInitialModelDiscoveryForTesting() async {
        await waitForInitialModelDiscovery()
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
        await waitForInitialModelDiscovery()
        if let transcriber, isReady {
            return transcriber
        }
        if let storageError = checkStorage(), state == .notPrepared {
            state = .failed(storageError)
            throw storageError
        }
        let hadExistingLocalModel: Bool
        if case .unloaded = state {
            hadExistingLocalModel = true
        } else {
            hadExistingLocalModel = false
        }
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
            await Self.removeModelDirectoryContents(at: modelDirectory)
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
        let source = downloadSourceProvider()

        // `.github` (`L-010`): lay the model + tokenizer down from the project's
        // own GitHub release before handing off to WhisperKit, which then loads
        // straight from disk with no HuggingFace access. Only when nothing valid
        // is on disk yet — an already-verified local model is never re-fetched
        // on a source change (`AT-093`). This is the path that works from
        // mainland China, where both HuggingFace hosts are unreachable.
        if source.usesDirectArchive {
            // Fetch only what's missing. The tokenizer lives in the app's own
            // directory (`tokenizerFolder`), separate from the model — a user
            // who already has the model on disk but whose tokenizer WhisperKit
            // previously left in `~/Documents/huggingface` still needs the
            // ~640 KB tokenizer laid down here, or the local load would fall
            // back to fetching it from an unreachable HuggingFace.
            let needsModel = LocalModelDetection.discoverModelFolder(in: modelDirectory) == nil
            let needsTokenizer = !Self.tokenizerPresent(in: modelDirectory)
            if needsModel || needsTokenizer {
                try await downloadFromGitHub(model: needsModel, tokenizer: needsTokenizer)
            }
        }

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

    /// Fetches the model and tokenizer archives from the project's GitHub
    /// release and unpacks them into the exact on-disk layout WhisperKit's
    /// local-load path expects (`L-010`). Progress is forwarded through the
    /// same `handleDownloadProgress` pipeline as the HuggingFace path, so the
    /// HUD/onboarding "N из 626 МБ" UI is identical. Throws on cancel/failure;
    /// `GitHubModelDownloader` cleans its own temp files on every exit.
    private func downloadFromGitHub(model: Bool, tokenizer: Bool) async throws {
        let workDirectory = modelDirectory.appendingPathComponent(".github-download", isDirectory: true)
        let downloader = GitHubModelDownloader(workDirectory: workDirectory)
        activeDownloader = downloader
        defer { activeDownloader = nil }

        let modelDestination = modelDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
        let tokenizerDestination = Self.tokenizerDirectory(in: modelDirectory)

        var archives: [GitHubModelDownloader.Archive] = []
        if model {
            archives.append(GitHubModelDownloader.Archive(
                url: ModelCatalog.githubModelArchiveURL,
                destination: modelDestination,
                expectedChild: ModelCatalog.modelFolderName,
                // The tokenizer is ~640 KB against the model's ~450 MB, so it
                // barely moves the bar; give the model essentially all of it.
                progressWeight: tokenizer ? 0.99 : 1.0
            ))
        }
        if tokenizer {
            archives.append(GitHubModelDownloader.Archive(
                url: ModelCatalog.githubTokenizerArchiveURL,
                destination: tokenizerDestination,
                expectedChild: ModelCatalog.tokenizerRepoPath,
                progressWeight: model ? 0.01 : 1.0
            ))
        }
        guard !archives.isEmpty else { return }

        Task { await DiagnosticLog.shared.log("model.github.download.start") }
        do {
            try await downloader.fetchAll(archives) { [weak self] fraction in
                Task { @MainActor in self?.handleDownloadProgress(fraction: fraction) }
            }
            Task { await DiagnosticLog.shared.log("model.github.download.success") }
        } catch {
            Task { await DiagnosticLog.shared.log("model.github.download.failed", detail: String(describing: error)) }
            throw error
        }
    }

    /// Settings/onboarding "Отменить загрузку": stops the in-flight GitHub
    /// archive download. The partial file is discarded by the downloader's own
    /// cleanup; `deleteModel()` clears anything already written so the user can
    /// switch source and start fresh. No-op for the HuggingFace path (WhisperKit
    /// owns that transfer) beyond dropping back to `.notPrepared` via delete.
    public func cancelDownload() {
        let downloader = activeDownloader
        Task { await downloader?.cancel() }
    }

    /// Removes everything under `modelDirectory` (recreating the empty
    /// directory) so a corrupt/partial model can't be mistaken for a valid
    /// one on the next attempt. `modelDirectory` is exclusively owned by
    /// this app for model storage (see `App`'s setup), so this is safe.
    nonisolated private static func removeModelDirectoryContents(at directory: URL) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }.value
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

    /// Settings "Удалить модель" (`AT-094`, `L-010`): unloads the model from
    /// memory (if resident), wipes the on-disk `Models` directory, and drops
    /// back to `.notPrepared` so `ReadinessCoordinator` reports `.needsModel`
    /// (`INV-015`) until the user explicitly re-downloads. Safe to call from
    /// any `state` — including when nothing is loaded/downloaded yet — since
    /// both `unloadTask` cancellation and `removeModelDirectoryContents()`
    /// are idempotent. Deliberately doesn't touch history/dictionary/settings
    /// (`L-010`): those live in separate stores this method never reaches.
    public func deleteModel() async {
        unloadTask?.cancel()
        unloadTask = nil
        transcriber = nil
        // A discovery that started before deletion can otherwise report an
        // old positive result after the directory has already been emptied.
        initialModelDiscoveryTask?.cancel()
        initialModelDiscoveryTask = nil
        initialModelDiscoveryToken = nil
        state = .notPrepared
        await Self.removeModelDirectoryContents(at: modelDirectory)
        Task { await DiagnosticLog.shared.log("model.delete") }
    }

    public static func defaultTranscriberFactory(
        modelDirectory: URL,
        endpoint: String,
        downloadProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Transcribing {
        try await WhisperKitTranscriber(
            modelDirectory: modelDirectory,
            endpoint: endpoint,
            // Keep the tokenizer inside the app's own model directory instead
            // of WhisperKit's default `~/Documents/huggingface` — the app must
            // not litter the user's Documents folder, and the `.github` source
            // pre-places the tokenizer here for fully-offline loading.
            tokenizerFolder: Self.tokenizerDirectory(in: modelDirectory),
            downloadProgress: downloadProgress
        )
    }

    /// Hub base for the tokenizer, inside the app's model directory. WhisperKit
    /// resolves the tokenizer at `<this>/models/openai/whisper-large-v3`.
    nonisolated static func tokenizerDirectory(in modelDirectory: URL) -> URL {
        modelDirectory.appendingPathComponent("tokenizers", isDirectory: true)
    }

    /// Whether the tokenizer is already laid down in the app's own directory
    /// (so no HuggingFace fetch is needed on load). Checks the concrete
    /// `tokenizer.json`, not just the folder, so a half-extracted archive
    /// doesn't read as present.
    nonisolated static func tokenizerPresent(in modelDirectory: URL) -> Bool {
        let tokenizerJSON = tokenizerDirectory(in: modelDirectory)
            .appendingPathComponent(ModelCatalog.tokenizerRepoPath, isDirectory: true)
            .appendingPathComponent("tokenizer.json")
        return FileManager.default.fileExists(atPath: tokenizerJSON.path)
    }
}
