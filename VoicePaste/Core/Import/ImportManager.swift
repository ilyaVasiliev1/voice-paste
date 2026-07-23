import Dispatch
import Foundation

nonisolated private enum ImportManagerError: Error, Sendable {
    case persistenceFailed
}

/// Coalesces worker progress before it creates any MainActor work. Video
/// extraction can emit one callback per audio sample buffer (dozens per
/// second); previously every one allocated a main-actor `Task` and only then
/// got throttled, which could backlog SwiftUI behind a long import.
nonisolated final class ImportProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastDeliveryNanos: UInt64 = 0
    private let minimumIntervalNanos: UInt64 = 250_000_000

    func shouldDeliver(_ value: Double) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        defer { lock.unlock() }
        guard value >= 0.999 || now - lastDeliveryNanos >= minimumIntervalNanos else {
            return false
        }
        lastDeliveryNanos = now
        return true
    }
}

/// Small actor-owned result, while decoded PCM windows are released after
/// each inference. Only text grows with media duration, not audio memory.
private actor ImportTranscriptAccumulator {
    private var text = ""
    private var detectedLanguage: String?

    func append(_ result: TranscriptionResult) {
        text = TranscriptChunkMerger.merge(text, with: result.rawText)
        if detectedLanguage == nil { detectedLanguage = result.detectedLanguage }
    }

    func result() -> TranscriptionResult {
        TranscriptionResult(rawText: text, detectedLanguage: detectedLanguage)
    }
}

/// One local FIFO worker for every import trigger. Staging, decoding and
/// transcription never happen in a drop handler, so the main window/HUD stay
/// responsive and all work survives closing the main window.
@MainActor
public final class ImportManager: ObservableObject {
    public struct Completion: Equatable, Sendable {
        public let jobID: UUID
        public let transcript: Transcript
    }

    @Published public private(set) var jobs: [ImportJob] = []
    @Published public private(set) var lastCompletion: Completion?

    private let decoder: AudioDecoder
    private let modelManager: ModelManager
    private let normalizer: TextNormalizer
    private let historyStore: any HistoryStoring
    private let queueStore: any ImportQueueStoring
    private let settings: AppSettings
    private var workerTask: Task<Void, Never>?
    private var activeJobID: UUID?
    private var stagingTasks: [UUID: Task<Void, Never>] = [:]

    public init(
        modelManager: ModelManager,
        historyStore: any HistoryStoring,
        queueStore: any ImportQueueStoring,
        settings: AppSettings,
        decoder: AudioDecoder = AudioDecoder(),
        normalizer: TextNormalizer? = nil
    ) {
        self.modelManager = modelManager
        self.historyStore = historyStore
        self.queueStore = queueStore
        self.settings = settings
        self.decoder = decoder
        self.normalizer = normalizer ?? TextNormalizer()
    }

    public var currentJob: ImportJob? {
        guard let activeJobID else { return nil }
        return jobs.first { $0.id == activeJobID }
    }

    public var activeQueueCount: Int {
        jobs.filter { $0.state.isActive }.count
    }

    /// Restores interrupted tasks after process relaunch. The persistent
    /// store resets an interrupted worker to `queued`; a missing cache source
    /// becomes a visible failure instead of silently creating an empty text.
    public func restoreQueue() {
        Task { [weak self] in
            guard let self else { return }
            let restored = (try? await queueStore.restoreJobs()) ?? []
            jobs = restored
            startWorkerIfNeeded()
        }
    }

    /// Starts staging immediately and returns before the source file is
    /// copied. The original URL is never retained after that short copy.
    @discardableResult
    public func enqueue(url: URL) -> UUID {
        let job = ImportJob(
            fileName: url.lastPathComponent,
            mediaKind: Self.mediaKind(for: url)
        )
        jobs.append(job)

        let task = Task { [weak self] in
            guard let self else { return }
            // Phase 1 is intentionally complete before any file-system work:
            // the job is already visible as “Копирование файла” in the
            // sidebar/detail and the HUD has switched to its responsive
            // processing state. Yielding one executor turn lets SwiftUI
            // commit that feedback before staging begins.
            await Task.yield()
            do {
                // The visible row is optimistic, but disk work only begins
                // after its durable queue record commits. This preserves FIFO
                // and crash recovery without a fire-and-forget write race.
                do {
                    try await queueStore.upsert(job)
                } catch {
                    throw ImportManagerError.persistenceFailed
                }
                // Cancellation may arrive while SwiftUI is committing the
                // immediately-visible queue row. Never start a disk copy
                // after that cancellation, otherwise a removed job can leave
                // a private cache folder behind.
                try Task.checkCancellation()
                guard SupportedImportFormat.isSupported(pathExtension: url.pathExtension) else {
                    throw AudioDecodeError.unsupportedFormat
                }
                try await Self.stage(url: url, for: job.id)
                try Task.checkCancellation()
                try await transition(job.id, to: .queued, progress: 0)
                stagingTasks.removeValue(forKey: job.id)
                startWorkerIfNeeded()
            } catch is CancellationError {
                try? await removeJob(job.id, removePersistentRecord: true)
                await Self.removeCache(for: job.id)
            } catch {
                stagingTasks.removeValue(forKey: job.id)
                await fail(job.id, error: error)
                await Self.removeCache(for: job.id)
            }
        }
        stagingTasks[job.id] = task
        return job.id
    }

    public func cancel(id: UUID) {
        if activeJobID == id {
            workerTask?.cancel()
            return
        }
        stagingTasks.removeValue(forKey: id)?.cancel()
        Task { [weak self] in
            guard let self else { return }
            try? await removeJob(id, removePersistentRecord: true)
            await Self.removeCache(for: id)
        }
    }

    public func dismissFailed(id: UUID) {
        guard jobs.first(where: { $0.id == id })?.state == .failed else { return }
        Task { [weak self] in
            guard let self else { return }
            try? await removeJob(id, removePersistentRecord: true)
            await Self.removeCache(for: id)
        }
    }

    /// A failed decode/transcription keeps only its already-staged temporary
    /// source. Retrying therefore does not ask Finder again and never needs
    /// to retain the original path or security-scoped bookmark. Deleting the
    /// failed row removes that private cache immediately.
    public func retry(id: UUID) async {
        guard let job = jobs.first(where: { $0.id == id }), job.state == .failed,
              FileManager.default.fileExists(
                atPath: Self.sourceURL(for: id, pathExtension: URL(fileURLWithPath: job.fileName).pathExtension).path
              ) else {
            return
        }
        do {
            try await update(id) {
                $0.state = .queued
                $0.progress = 0
                $0.failureKey = nil
                $0.stageStartedAt = Self.nowMillis()
            }
        } catch {
            await fail(id, error: error)
            return
        }
        startWorkerIfNeeded()
    }

    public func canRetry(id: UUID) -> Bool {
        guard let job = jobs.first(where: { $0.id == id }), job.state == .failed else { return false }
        return FileManager.default.fileExists(
            atPath: Self.sourceURL(for: id, pathExtension: URL(fileURLWithPath: job.fileName).pathExtension).path
        )
    }

    private func startWorkerIfNeeded() {
        guard workerTask == nil else { return }
        workerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let next = jobs.first(where: { $0.state == .queued }) else { break }
                activeJobID = next.id
                await process(next.id)
                activeJobID = nil
            }
            workerTask = nil
            if jobs.contains(where: { $0.state == .queued }) { startWorkerIfNeeded() }
        }
    }

    private func process(_ id: UUID) async {
        guard let initial = jobs.first(where: { $0.id == id }) else { return }
        let sourceURL = Self.sourceURL(for: initial.id, pathExtension: URL(fileURLWithPath: initial.fileName).pathExtension)
        defer {
            modelManager.endTask(unloadMinutes: settings.modelUnloadMinutes)
        }

        do {
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw AudioDecodeError.decodeFailed("Staged source is unavailable.")
            }
            try await transition(id, to: .preparing, progress: 0.02)
            let progressGate = ImportProgressGate()
            let publishProgress: @Sendable (Double) -> Void = { [weak self, progressGate] value in
                // The gate runs on the decoder/inference executor, before a
                // `Task` is allocated. At most four updates per second can
                // reach the UI/database, regardless of video frame rate.
                guard progressGate.shouldDeliver(value) else { return }
                Task { @MainActor [weak self] in
                    self?.updateProgress(id, value: value)
                }
            }
            let engine = try await modelManager.ensureLoaded()
            try await update(id) {
                $0.state = .transcribing
                $0.progress = max($0.progress, 0.05)
                $0.stageStartedAt = Self.nowMillis()
            }

            let decoder = decoder
            let language = settings.languageMode
            let accumulator = ImportTranscriptAccumulator()
            let mediaProgress: @Sendable (Double) -> Void = { value in
                publishProgress(0.05 + value * 0.94)
            }
            // The decoder awaits this closure before retaining the next
            // window. A three-hour file therefore has the same PCM footprint
            // as a short file (`INV-018`, `AT-100`).
            let uniqueSampleCount = try await decoder.decodeInChunks(
                url: sourceURL,
                onProgress: mediaProgress
            ) { chunk in
                try Task.checkCancellation()
                let result = try await engine.transcribe(TranscriptionRequest(
                    samples: chunk.samples,
                    language: language
                ))
                await accumulator.append(result)
            }
            try Task.checkCancellation()
            let result = await accumulator.result()
            let duration = Int(Double(uniqueSampleCount) / 16_000 * 1_000)
            try await update(id) { $0.durationMilliseconds = duration }

            let vocabulary = (try? await historyStore.fetchVocabulary()) ?? []
            let (text, _) = await normalizer.normalizeInBackground(
                rawText: result.rawText,
                language: settings.languageMode,
                vocabulary: vocabulary,
                autoCorrectSafeTypos: settings.autoCorrectSafeTypos
            )
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TranscribingError.emptyAudio
            }
            let now = Self.nowMillis()
            let transcript = Transcript(
                id: UUID(), createdAt: now, updatedAt: now, source: .file,
                sourceFileName: initial.fileName, durationMilliseconds: duration,
                language: result.detectedLanguage, rawText: result.rawText, text: text,
                preview: Transcript.makePreview(from: text), status: .completed,
                insertionOutcome: .notRequested
            )
            // History is optional. A disabled history must never turn a
            // successful local transcription into an artificial import
            // error: the HUD can still offer the finished text for copying.
            if settings.historyEnabled {
                do {
                    try await historyStore.save(transcript)
                } catch {
                    // The transcription itself is already complete and must
                    // remain copyable even if optional history persistence is
                    // unavailable. Startup database failures are disclosed by
                    // MainWindowView's persistent banner; diagnostics retain
                    // the technical reason without logging transcript text.
                    Task {
                        await DiagnosticLog.shared.log(
                            "import.historySaveFailed",
                            detail: String(describing: error)
                        )
                    }
                }
            }
            lastCompletion = Completion(jobID: id, transcript: transcript)
            try await removeJob(id, removePersistentRecord: true)
            await Self.removeCache(for: id)
        } catch is CancellationError {
            try? await removeJob(id, removePersistentRecord: true)
            await Self.removeCache(for: id)
        } catch {
            await fail(id, error: error)
            // Keep the staged source only while the failed row is visible:
            // the user can retry without finding the file again. dismissFailed
            // and every cancellation path remove it deterministically.
        }
    }

    private func updateProgress(_ id: UUID, value: Double) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].progress = max(jobs[index].progress, min(value, 0.99))
        // Progress is transient UI, not a durable state transition. Avoid a
        // 4 Hz SQLite write stream and persist only stage boundaries.
    }

    private func transition(_ id: UUID, to state: ImportJob.State, progress: Double) async throws {
        try await update(id) {
            $0.state = state
            $0.progress = progress
            $0.stageStartedAt = Self.nowMillis()
            $0.failureKey = nil
        }
    }

    private func fail(_ id: UUID, error: Error) async {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = .failed
        jobs[index].failureKey = Self.errorKey(for: error)
        jobs[index].stageStartedAt = Self.nowMillis()
        try? await queueStore.upsert(jobs[index])
    }

    private func update(_ id: UUID, mutate: (inout ImportJob) -> Void) async throws {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&jobs[index])
        do { try await queueStore.upsert(jobs[index]) }
        catch { throw ImportManagerError.persistenceFailed }
    }

    private func removeJob(_ id: UUID, removePersistentRecord: Bool) async throws {
        if removePersistentRecord {
            do { try await queueStore.delete(id: id) }
            catch { throw ImportManagerError.persistenceFailed }
        }
        jobs.removeAll { $0.id == id }
    }

    nonisolated private static func stage(url: URL, for id: UUID) async throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let destination = sourceURL(for: id, pathExtension: url.pathExtension)
        try await Task.detached(priority: .utility) {
            let manager = FileManager.default
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            try manager.copyItem(at: url, to: destination)
        }.value
    }

    nonisolated private static func removeCache(for id: UUID) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: cacheDirectory(for: id))
        }.value
    }

    nonisolated public static func sourceURL(for id: UUID, pathExtension: String) -> URL {
        cacheDirectory(for: id).appendingPathComponent("source.\(pathExtension.lowercased())")
    }

    nonisolated public static func cacheDirectory(for id: UUID) -> URL {
        let base = (try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("VoicePaste/ImportQueue/\(id.uuidString)", isDirectory: true)
    }

    nonisolated private static func mediaKind(for url: URL) -> ImportJob.MediaKind {
        switch url.pathExtension.lowercased() {
        case "mp4", "mov", "m4v": .video
        default: .audio
        }
    }

    nonisolated private static func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }

    nonisolated private static func errorKey(for error: Error) -> String {
        switch error {
        case AudioDecodeError.unsupportedFormat: return "import.error.unsupportedFormat"
        case AudioDecodeError.noAudioTrack: return "import.error.noAudioTrack"
        case AudioDecodeError.decodeFailed: return "import.error.decodeFailed"
        case TranscribingError.emptyAudio: return "dictation.emptyAudio"
        case ImportManagerError.persistenceFailed: return "import.error.persistenceFailed"
        default: return "import.error.transcriptionFailed"
        }
    }
}
