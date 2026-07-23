import AVFoundation
import XCTest
@testable import VoicePaste

private actor RecordingImportTranscriber: Transcribing {
    private var sampleCounts: [Int] = []

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        sampleCounts.append(request.samples.count)
        return TranscriptionResult(rawText: "Тестовый сегмент", detectedLanguage: "ru")
    }

    func snapshot() -> [Int] { sampleCounts }
}

/// Queue-level acceptance tests for local file imports. They intentionally
/// use the real decoder and a deterministic transcriber: no test downloads
/// or invokes WhisperKit, while the same staging/FIFO/cleanup path runs.
@MainActor
final class ImportManagerTests: XCTestCase {
    private var scratchDirectory: URL!
    private var defaultsSuite: String!

    override func setUp() async throws {
        try await super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoicePasteTests-Import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        defaultsSuite = "VoicePasteTests-Import-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        if let scratchDirectory { try? FileManager.default.removeItem(at: scratchDirectory) }
        if let defaultsSuite { UserDefaults.standard.removePersistentDomain(forName: defaultsSuite) }
        scratchDirectory = nil
        defaultsSuite = nil
        try await super.tearDown()
    }

    private func makeSilentWAV(seconds: Double = 0.2, name: String = "note.wav") throws -> URL {
        let url = scratchDirectory.appendingPathComponent(name)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 16_000))!
        buffer.frameLength = buffer.frameCapacity
        try file.write(from: buffer)
        return url
    }

    private func makeManager(transcriber: some Transcribing) -> ImportManager {
        let settings = AppSettings(defaults: UserDefaults(suiteName: defaultsSuite)!)
        settings.modelUnloadMinutes = 0
        let modelManager = ModelManager(
            modelDirectory: scratchDirectory,
            makeTranscriber: { _, _, _ in transcriber }
        )
        return ImportManager(
            modelManager: modelManager,
            historyStore: FailingHistoryStore(),
            queueStore: InMemoryImportQueueStore(),
            settings: settings
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 6,
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(predicate(), "Timed out waiting for queue state")
    }

    func test_AT021_importsSupportedWAV_producesCompletionAndCleansOwnedCache() async throws {
        let url = try makeSilentWAV()
        let manager = makeManager(
            transcriber: MockTranscriber(result: .success(.init(rawText: "Тестовая расшифровка.", detectedLanguage: "ru")))
        )

        let jobID = manager.enqueue(url: url)
        try await waitUntil { manager.lastCompletion?.jobID == jobID }

        let transcript = try XCTUnwrap(manager.lastCompletion?.transcript)
        XCTAssertEqual(transcript.text, "Тестовая расшифровка.")
        XCTAssertEqual(transcript.source, .file)
        XCTAssertEqual(transcript.sourceFileName, "note.wav")
        XCTAssertGreaterThan(transcript.durationMilliseconds, 0)
        XCTAssertTrue(manager.jobs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ImportManager.cacheDirectory(for: jobID).path))
    }

    func test_AT022_unsupportedFile_remainsVisibleAsFailedWithoutCompletion() async throws {
        let url = scratchDirectory.appendingPathComponent("broken.xyz")
        try Data("not a media file".utf8).write(to: url)
        let manager = makeManager(transcriber: MockTranscriber())

        let jobID = manager.enqueue(url: url)
        try await waitUntil { manager.jobs.first(where: { $0.id == jobID })?.state == .failed }

        XCTAssertNil(manager.lastCompletion)
        XCTAssertEqual(manager.jobs.first(where: { $0.id == jobID })?.failureKey, "import.error.unsupportedFormat")
    }

    func test_AT025_cancelledStaging_removesJobAndCache() async throws {
        let url = try makeSilentWAV(seconds: 0.5, name: "cancel.wav")
        let manager = makeManager(transcriber: MockTranscriber())
        let jobID = manager.enqueue(url: url)

        manager.cancel(id: jobID)
        try await waitUntil { !manager.jobs.contains(where: { $0.id == jobID }) }

        XCTAssertNil(manager.lastCompletion)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ImportManager.cacheDirectory(for: jobID).path))
    }

    func test_AT038_restoredInterruptedJobs_areRequeuedInFIFOOrder() async throws {
        let store = InMemoryImportQueueStore()
        let first = ImportJob(fileName: "one.mp4", createdAt: 1, mediaKind: .video, state: .transcribing, progress: 0.7)
        let second = ImportJob(fileName: "two.m4a", createdAt: 2, mediaKind: .audio, state: .queued)
        try await store.upsert(first)
        try await store.upsert(second)

        let restored = try await store.restoreJobs()

        XCTAssertEqual(restored.map(\.id), [first.id, second.id])
        XCTAssertEqual(restored.map(\.state), [.queued, .queued])
        XCTAssertEqual(restored.map(\.progress), [0, 0])
    }

    func test_AT051_progressBurstIsCoalescedBeforeItCanScheduleUIWork() {
        let gate = ImportProgressGate()

        XCTAssertTrue(gate.shouldDeliver(0.10))
        for _ in 0..<100 {
            XCTAssertFalse(gate.shouldDeliver(0.11))
        }
        // A terminal update must not wait for the 250 ms interval.
        XCTAssertTrue(gate.shouldDeliver(1))
    }

    func test_AT100_longImportIsTranscribedInBoundedSequentialWindows() async throws {
        let url = try makeSilentWAV(seconds: 65, name: "long.wav")
        let transcriber = RecordingImportTranscriber()
        let manager = makeManager(transcriber: transcriber)

        let jobID = manager.enqueue(url: url)
        try await waitUntil(timeout: 15) { manager.lastCompletion?.jobID == jobID }

        let counts = await transcriber.snapshot()
        XCTAssertGreaterThan(counts.count, 1)
        XCTAssertLessThanOrEqual(counts.max() ?? .max, Int(28.75 * 16_000) + 2_048)
        let duration = try XCTUnwrap(manager.lastCompletion?.transcript.durationMilliseconds)
        XCTAssertEqual(duration, 65_000, accuracy: 50)
    }
}
