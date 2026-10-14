import Foundation

@testable import VoicePaste

// Подставные части тракта диктовки: микрофон, вставка, плашка, модель, журнал, звук для оценки.

@MainActor
final class FakeAudioSource: AudioSource {
    var isCapturing = false
    var lastCaptureRMS: Float = 0
    var capturedSampleCount: Int { recording.count }
    var onLevel: ((Float) -> Void)?
    var onAudioChunk: (@Sendable ([Float]) -> Void)?
    var onInterruption: ((AudioCaptureInterruption) -> Void)?
    var recording: [Float] = []
    var recordingRMS: Float = 0
    private(set) var startCount = 0

    func start() throws {
        startCount += 1
        isCapturing = true
    }
    func resume() throws { isCapturing = true }
    func pause() { isCapturing = false }
    func stop() -> [Float] {
        isCapturing = false
        lastCaptureRMS = recordingRMS
        return recording
    }
    func capturedSamples(in range: Range<Int>) -> [Float] {
        Array(recording[range.clamped(to: 0..<recording.count)])
    }
}

@MainActor
final class FakeTextDelivery: TextDelivering {
    var outcome: InsertionOutcome = .inserted
    private(set) var inserted: [String] = []
    private(set) var copied: [String] = []
    func captureFrontApp() -> FrontAppSnapshot? {
        FrontAppSnapshot(bundleIdentifier: "test.app", processIdentifier: 1)
    }
    func insert(_ text: String, into snapshot: FrontAppSnapshot?) -> InsertionOutcome {
        inserted.append(text)
        return outcome
    }
    func copyToClipboard(_ text: String) { copied.append(text) }
}

@MainActor
final class FakeHUD: HUDPresenting {
    private(set) var states: [HUDState] = []
    func present(_ state: HUDState) { states.append(state) }
    func hide() { states.append(.hidden) }
    var last: HUDState? { states.last }
}

/// Вызовы модели считаются под замком: распознавание идёт вне главного актора.
final class CountingTranscriber: Transcribing, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [TranscriptionRequest] = []
    var result: Result<TranscriptionResult, Error>

    init(result: Result<TranscriptionResult, Error>) { self.result = result }

    var callCount: Int { lock.withLock { requests.count } }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        lock.withLock { requests.append(request) }
        return try result.get()
    }
}

/// Журнал событий под замком: запись приходит с фоновой задачи.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(event: String, detail: String)] = []

    func append(_ event: String, _ detail: String) {
        lock.withLock { entries.append((event, detail)) }
    }

    func details(of event: String) -> [String] {
        lock.withLock { entries.filter { $0.event == event }.map(\.detail) }
    }

    var order: [String] { lock.withLock { entries.map(\.event) } }
}

/// Хранилище звука для оценки: что и под каким именем сохранили.
final class FakeEvaluationAudio: EvaluationAudioStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storedFiles: [(id: UUID, sampleCount: Int)] = []
    private var storedFailure: Error?
    private var storedDelay: Duration = .zero
    private var storedDeletedIDs: [UUID] = []
    private var storedDeleteAllCount = 0
    private var storedDeleteFailure: Error?

    var saved: [(id: UUID, sampleCount: Int)] { lock.withLock { storedFiles } }

    var deletedIDs: [UUID] { lock.withLock { storedDeletedIDs } }
    var deleteAllCount: Int { lock.withLock { storedDeleteAllCount } }

    func setDeleteFailure(_ error: Error?) { lock.withLock { storedDeleteFailure = error } }

    func delete(id: UUID) async throws {
        if let failure = lock.withLock({ storedDeleteFailure }) { throw failure }
        lock.withLock { storedDeletedIDs.append(id) }
    }

    func setFailure(_ error: Error?) { lock.withLock { storedFailure = error } }
    func setSaveDelay(_ delay: Duration) { lock.withLock { storedDelay = delay } }

    func save(samples: [Float], id: UUID) async throws {
        let (delay, failure) = lock.withLock { (storedDelay, storedFailure) }
        if delay > .zero { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        lock.withLock { storedFiles.append((id, samples.count)) }
    }

    func summary() async -> EvaluationAudioSummary {
        EvaluationAudioSummary(fileCount: saved.count, totalBytes: 0)
    }

    func deleteAll() async throws -> Int {
        if let failure = lock.withLock({ storedDeleteFailure }) { throw failure }
        return lock.withLock {
            storedDeleteAllCount += 1
            defer { storedFiles.removeAll() }
            return storedFiles.count
        }
    }
}
