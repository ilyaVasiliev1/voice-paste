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
    @Published public private(set) var state: ModelState = .notPrepared {
        didSet {
            // Every state change is recorded, because "почему опять грузится
            // модель?" is otherwise unanswerable after the fact. Progress ticks
            // within `.downloading` collapse into one line — `describe` omits
            // the numbers precisely so a 4 Hz download can't flood the log.
            let from = Self.describe(oldValue)
            let to = Self.describe(state)
            guard from != to else { return }
            Task { await DiagnosticLog.shared.log("model.state", detail: "\(from)→\(to)") }
        }
    }

    private var transcriber: Transcribing?
    private var unloadTask: Task<Void, Never>?
    /// The single in-flight load, shared by every concurrent `ensureLoaded()`
    /// caller (launch pre-warm + a dictation started while it runs).
    private var loadTask: Task<Transcribing, Error>?
    /// Identifies the current load so a late-finishing older one cannot clear
    /// a newer load's slot (`finishLoad(generation:)`).
    private var loadGeneration: UInt64 = 0
    /// `L-010`: the model is kept resident for instant dictation and given
    /// back when *the system* says it needs the memory — not on a fixed timer,
    /// which used to make every later dictation pay a reload for no reason.
    private var memoryPressureSource: DispatchSourceMemoryPressure?
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
        startMemoryPressureMonitoring()
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

    /// `L-001`/`UI-002`: the one place at launch that must *not* race the
    /// startup disk check. Readiness starts at `.notPrepared` (= "модель не
    /// скачана") until the background walk reports back; deciding whether to
    /// show onboarding before that lands makes a fully-configured app flash
    /// its first-run window for no reason. Awaiting here costs a directory
    /// walk of a few dozen file records and never blocks the main thread.
    public func awaitInitialModelDiscovery() async {
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
        // Coalesce concurrent loads (`L-010`): the launch pre-warm and a user
        // dictation that starts while it's still running must share ONE load —
        // otherwise the multi-minute Core ML compile would run twice.
        if let loadTask {
            return try await loadTask.value
        }
        // The task clears `loadTask` itself when it finishes, rather than the
        // caller doing it in a `defer`. With the old `defer`, a caller whose
        // own task got cancelled while awaiting would clear the slot while the
        // load kept running — and the next `ensureLoaded()` would then start a
        // *second* concurrent load of the same 600 MB model, doubling the Core
        // ML compile and the memory it needs.
        loadGeneration &+= 1
        let generation = loadGeneration
        let task = Task<Transcribing, Error> { [weak self] in
            guard let self else { throw ModelError.downloadFailed }
            do {
                let engine = try await self.performLoad()
                self.finishLoad(generation: generation)
                return engine
            } catch {
                self.finishLoad(generation: generation)
                throw error
            }
        }
        loadTask = task
        return try await task.value
    }

    /// Releases the shared load slot, but only if it still belongs to this
    /// load — a newer `ensureLoaded()` must never have its task cleared by an
    /// older one finishing late.
    private func finishLoad(generation: UInt64) {
        guard loadGeneration == generation else { return }
        loadTask = nil
    }

    /// Pre-warms the model in the background so the *first* dictation doesn't
    /// pay the one-time Core ML compile (observed ~45 s on `large-v3`).
    /// Fire-and-forget and idempotent: `ensureLoaded()` coalesces, so a
    /// dictation started mid-pre-warm joins the same load instead of queueing
    /// a second one. Called once the app reaches `ready` (`L-001`).
    public func prewarm() {
        guard transcriber == nil, loadTask == nil else { return }
        // Only when the model is already verified on disk. `.notPrepared` must
        // stay a deliberate user action — pre-warm never starts a 626 MB
        // download by itself.
        guard case .unloaded = state else { return }
        Task { [weak self] in
            _ = try? await self?.ensureLoaded()
        }
    }

    private func performLoad() async throws -> Transcribing {
        if let storageError = checkStorage(), state == .notPrepared {
            state = .failed(storageError)
            throw storageError
        }
        // Read the filesystem, not `state`. Deriving "a model exists" from
        // `state == .unloaded` was wrong in every other state the loader can
        // legitimately start from (`.ready` after a memory-pressure release,
        // `.failed` on a manual retry) — and this flag decides whether 600 MB
        // of the user's disk gets deleted, so it must reflect reality.
        let hadExistingLocalModel = LocalModelDetection.discoverModelFolder(in: modelDirectory) != nil
        do {
            return try await loadWithAutoRetry()
        } catch {
            Task { await DiagnosticLog.shared.log("model.load.failed", detail: String(describing: error)) }

            // Cancellation is not a model failure: leave both the files and
            // the state alone so a cancelled pre-warm can't mark the app
            // broken.
            if error is CancellationError {
                throw error
            }

            // `INV-004`: the local model is deleted ONLY when the error proves
            // the files themselves are unreadable, and only if it is still
            // there to be deleted.
            //
            // Real-world regression this guards: from mainland China WhisperKit
            // could fail with a *network* error (`RetriableDownloadFailure`)
            // while loading a perfectly good on-disk model, because it still
            // reaches out to HuggingFace for the tokenizer. The old code read
            // any error as "локальная модель битая", wiped the whole 626 MB
            // model and dropped into a re-download that could not succeed on
            // that network — turning a momentary hiccup into a dead app with a
            // red menu-bar icon. Seen repeatedly in the diagnostic log.
            guard hadExistingLocalModel,
                  Self.indicatesUnreadableLocalModel(error),
                  let corruptFolder = LocalModelDetection.discoverModelFolder(in: modelDirectory) else {
                state = .failed(.downloadFailed)
                throw error
            }

            // The folder that `LocalModelDetection` trusted turned out to be
            // unloadable — corrupt/truncated rather than merely "not yet
            // downloaded". Wipe the model payload so the next attempt can't
            // find it and falls through to a clean download. The tokenizer is
            // deliberately kept: it is a separate 640 KB artifact that has
            // nothing to do with a corrupt Core ML bundle, and re-fetching it
            // is exactly what the network failure above cannot do.
            Task { await DiagnosticLog.shared.log("model.local.invalid", detail: String(describing: error)) }
            await Self.removeModelPayload(at: corruptFolder, keepingTokenizersUnder: modelDirectory)
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

    /// Whether a load error means the on-disk model files are unreadable — the
    /// only justification for deleting them (`performLoad()`).
    ///
    /// Pure and `nonisolated` so it is directly unit-testable. Deliberately
    /// fails *closed*: anything unrecognised returns `false` and the user keeps
    /// their model. A wrong `true` costs a 626 MB re-download on a network
    /// where that may be impossible; a wrong `false` costs one honest error
    /// message and a "Повторить" button.
    nonisolated static func indicatesUnreadableLocalModel(_ error: Error) -> Bool {
        let nsError = error as NSError
        // Anything the URL loading system reports is a transport problem, full
        // stop — it says nothing about the bytes already on disk.
        if error is URLError || nsError.domain == NSURLErrorDomain { return false }

        // Core ML speaks only about the model files it was handed. Checked
        // before the text markers below because its own wording ("Error in
        // reading the MIL network") contains the word "network" while having
        // nothing to do with networking.
        if nsError.domain == "com.apple.CoreML" { return true }

        let text = String(describing: error).lowercased()
        // WhisperKit/Hub transport signatures. Deliberately specific — a bare
        // "network" substring would misread Core ML's own message.
        let networkMarkers = [
            "retriabledownloadfailure", "invalidmetadata", "metadata must have been retrieved",
            "timed out", "timeout", "connection", "offline", "unreachable",
            "hostname", "http status", "urlerror", "no internet"
        ]
        if networkMarkers.contains(where: { text.contains($0) }) { return false }

        let corruptMarkers = [
            "model.mil", "mil network", "mlmodelc", "mlpackage", "corrupt",
            "failed to parse", "cannot be read", "compiling", "compilation"
        ]
        return corruptMarkers.contains(where: { text.contains($0) })
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
        // Only a genuinely absent model means a network download. An on-disk
        // model is just being brought into memory — report `.preparing`, which
        // keeps the app `ready` and doesn't claim a 626 MB fetch is happening.
        if LocalModelDetection.discoverModelFolder(in: modelDirectory) == nil {
            state = .downloading(ModelDownloadProgress(
                completedBytes: 0,
                totalBytes: ModelCatalog.approximateSizeBytes,
                fraction: 0
            ))
        } else {
            state = .preparing
        }
        Task { await DiagnosticLog.shared.log("model.load.start") }
        let endpoint = downloadEndpointProvider()
        let source = downloadSourceProvider()

        // `.github` (`L-010`): lay the model + tokenizer down from the project's
        // own GitHub release before handing off to WhisperKit, which then loads
        // straight from disk with no HuggingFace access. Only when nothing valid
        // is on disk yet — an already-verified local model is never re-fetched
        // on a source change (`AT-093`). This is the path that works from
        // mainland China, where both HuggingFace hosts are unreachable.
        // Fetch only what's missing. The tokenizer lives in the app's own
        // directory (`tokenizerFolder`), separate from the model — a user who
        // already has the model on disk but whose tokenizer WhisperKit
        // previously left in `~/Documents/huggingface` still needs the ~640 KB
        // tokenizer laid down here, or the local load would fall back to
        // fetching it from an unreachable HuggingFace.
        let needsModel = LocalModelDetection.discoverModelFolder(in: modelDirectory) == nil
        let needsTokenizer = !Self.tokenizerPresent(in: modelDirectory)
        if source.usesDirectArchive {
            if needsModel || needsTokenizer {
                try await downloadFromGitHub(model: needsModel, tokenizer: needsTokenizer)
            }
        } else if needsTokenizer, !needsModel {
            // A local model with no local tokenizer is the one combination that
            // makes WhisperKit reach for HuggingFace on an otherwise offline
            // load — the exact call that failed from China and, before the
            // guard in `performLoad()`, got the model deleted. Lay the 640 KB
            // tokenizer down from the project's own release instead; it is a
            // static file, identical whichever host the model came from.
            //
            // Only when the model itself is already here: if the model is
            // being fetched from HuggingFace anyway, its tokenizer arrives on
            // that same trip and this would be a pointless second request.
            // Best-effort — on failure the old HuggingFace path still runs.
            try? await downloadFromGitHub(model: false, tokenizer: true)
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

    /// Removes only the Core ML model payload, leaving the tokenizer in place.
    /// Used by the corrupt-model recovery in `performLoad()`: a broken model
    /// bundle is no reason to throw away the separate 640 KB tokenizer, whose
    /// presence is exactly what lets the next load run without touching the
    /// network. The full wipe stays reserved for the user's explicit
    /// "Удалить модель" (`deleteModel()`).
    /// - Parameters:
    ///   - folder: the exact folder `LocalModelDetection` verified — removing
    ///     that, rather than a hard-coded relative path, keeps this correct
    ///     for both on-disk layouts (WhisperKit's nested
    ///     `models/argmaxinc/whisperkit-coreml/<variant>` and a model sitting
    ///     flat at the root).
    ///   - modelDirectory: the app's model root, used to locate the tokenizer
    ///     that must survive.
    nonisolated private static func removeModelPayload(
        at folder: URL,
        keepingTokenizersUnder modelDirectory: URL
    ) async {
        let tokenizers = tokenizerDirectory(in: modelDirectory).standardizedFileURL
        let root = modelDirectory.standardizedFileURL
        let target = folder.standardizedFileURL
        await Task.detached(priority: .utility) {
            guard target != root else {
                // The model sits flat at the root: clear its contents one by
                // one so the tokenizer directory alongside it survives.
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: modelDirectory,
                    includingPropertiesForKeys: nil
                )) ?? []
                for child in children where child.standardizedFileURL != tokenizers {
                    try? FileManager.default.removeItem(at: child)
                }
                return
            }
            try? FileManager.default.removeItem(at: target)
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

    /// Releases the resident model when macOS reports memory pressure, so the
    /// "keep it warm" default never starves the rest of the system. A load in
    /// flight is left alone (dropping it would just restart the compile); an
    /// in-flight transcription is unaffected because it holds its own strong
    /// reference to the engine and only this manager's reference is cleared.
    private func startMemoryPressureMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, self.loadTask == nil, self.transcriber != nil else { return }
                self.unloadNow()
                await DiagnosticLog.shared.log("model.unload", detail: "reason=memoryPressure")
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    /// `AT-026`/quit: releases the loaded model immediately.
    public func unloadNow() {
        unloadTask?.cancel()
        unloadTask = nil
        let wasResident = transcriber != nil
        let previousState = state
        transcriber = nil
        if case .ready = state {
            state = .unloaded
        }
        // Always report an actual release. The old version logged only from
        // `.ready`, so a release from any other state dropped the resident
        // model with no trace at all — which is precisely the situation that
        // makes a later "почему опять грузится?" impossible to explain.
        if wasResident {
            Task { await DiagnosticLog.shared.log("model.unload", detail: "from=\(Self.describe(previousState))") }
        }
    }

    /// Short, stable label for a state in diagnostics. Never includes progress
    /// numbers — those would make every 4 Hz tick a distinct log line.
    nonisolated static func describe(_ state: ModelState) -> String {
        switch state {
        case .notPrepared: return "notPrepared"
        case .downloading: return "downloading"
        case .preparing: return "preparing"
        case .verifying: return "verifying"
        case .ready: return "ready"
        case .unloaded: return "unloaded"
        case .failed: return "failed"
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
