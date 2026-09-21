import XCTest

@testable import VoicePaste

/// Потоковый путь лекции: выбор движка, разбор обновлений и их превращение
/// в абзацы.
///
/// Сам распознаватель системы здесь не поднимается — ему нужен живой звук и
/// macOS 26. Проверяется всё вокруг него через двойник `LiveTranscribing`.
@MainActor
final class LiveTranscriptionTests: XCTestCase {

    // MARK: - Выбор движка

    /// Умолчание следует за замером, а не за вкусом: на китайском система
    /// вчетверо быстрее и вдвое точнее, на русском Whisper точнее в разы.
    func test_defaultEngine_followsTheMeasuredWinnerPerLanguage() {
        XCTAssertEqual(LectureEngine.preferredIgnoringAvailability(for: .zh), .system)
        XCTAssertEqual(LectureEngine.preferredIgnoringAvailability(for: .ru), .whisper)
    }

    /// Автоопределения у системного распознавателя нет — язык задаётся до
    /// начала. Значит при «автоматически» остаётся только Whisper.
    func test_autoLanguage_alwaysGoesToWhisper() {
        XCTAssertEqual(LectureEngine.preferredIgnoringAvailability(for: .auto), .whisper)
    }

    // MARK: - Разбор обновлений

    func test_finalUpdate_becomesASegment() {
        let update = LiveTranscriptUpdate(text: " 今天我们学习。 ", isFinal: true, startSeconds: 1, endSeconds: 3)

        XCTAssertEqual(
            update.settledSegment,
            TranscribedSegment(text: "今天我们学习。", startSeconds: 1, endSeconds: 3)
        )
    }

    /// Уточняемый текст в абзацы не попадает: он ещё перепишется.
    func test_volatileUpdate_neverBecomesASegment() {
        let update = LiveTranscriptUpdate(text: "今天我们", isFinal: false, startSeconds: 1, endSeconds: 2)

        XCTAssertNil(update.settledSegment)
    }

    func test_emptyFinalUpdate_isDropped() {
        XCTAssertNil(LiveTranscriptUpdate(text: "   ", isFinal: true, startSeconds: 0, endSeconds: 1).settledSegment)
    }

    // MARK: - Лекция на потоковом движке

    func test_volatileTextIsShown_thenReplacedByTheSettledParagraph() async throws {
        let engine = FakeLiveEngine()
        let recorder = LectureRecorder()
        try await recorder.beginStreaming(engine: engine, language: .zh, pauseSeconds: 2)

        engine.emit(LiveTranscriptUpdate(text: "今天我们", isFinal: false, startSeconds: 0, endSeconds: 1))
        try await waitUntil { recorder.volatileText == "今天我们" }
        XCTAssertTrue(recorder.paragraphs.isEmpty, "уточняемый текст не должен становиться абзацем")

        engine.emit(LiveTranscriptUpdate(text: "今天我们学习。", isFinal: true, startSeconds: 0, endSeconds: 2))
        try await waitUntil { !recorder.paragraphs.isEmpty }

        XCTAssertEqual(recorder.paragraphs.first?.text, "今天我们学习。")
        XCTAssertEqual(recorder.volatileText, "", "устоявшийся кусок снимает уточняемый")
    }

    func test_audioIsForwardedToTheEngine() async throws {
        let engine = FakeLiveEngine()
        let recorder = LectureRecorder()
        try await recorder.beginStreaming(engine: engine, language: .zh, pauseSeconds: 2)

        recorder.appendStreamingAudio([0.1, 0.2, 0.3])

        XCTAssertEqual(engine.receivedSampleCount, 3)
    }

    func test_finishStreaming_closesTheEngineAndReturnsParagraphs() async throws {
        let engine = FakeLiveEngine()
        let recorder = LectureRecorder()
        try await recorder.beginStreaming(engine: engine, language: .zh, pauseSeconds: 2)
        engine.emit(LiveTranscriptUpdate(text: "第一段。", isFinal: true, startSeconds: 0, endSeconds: 2))
        try await waitUntil { !recorder.paragraphs.isEmpty }

        let paragraphs = await recorder.finishStreaming()

        XCTAssertTrue(engine.didFinish)
        XCTAssertEqual(paragraphs.map(\.text), ["第一段。"])
    }

    /// Язык, которого движок не знает, обязан всплыть ошибкой, а не молча
    /// оставить лекцию без расшифровки.
    func test_unsupportedLanguage_surfacesAsAnError() async {
        let engine = FakeLiveEngine(rejects: true)
        let recorder = LectureRecorder()

        do {
            try await recorder.beginStreaming(engine: engine, language: .auto, pauseSeconds: 2)
            XCTFail("Отказ движка обязан всплыть, а не проглотиться")
        } catch {
            XCTAssertEqual(error as? LiveTranscribingError, .unsupportedLanguage("auto"))
        }
    }

    // MARK: - Вспомогательное

    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Условие не наступило за \(timeout)")
    }
}

/// Двойник потокового движка: обновления подаются из теста вручную.
@MainActor
private final class FakeLiveEngine: LiveTranscribing {
    private let rejects: Bool
    private let stream: AsyncStream<LiveTranscriptUpdate>
    private let continuation: AsyncStream<LiveTranscriptUpdate>.Continuation
    private(set) var receivedSampleCount = 0
    private(set) var didFinish = false

    var updates: AsyncStream<LiveTranscriptUpdate> { stream }

    init(rejects: Bool = false) {
        self.rejects = rejects
        (stream, continuation) = AsyncStream<LiveTranscriptUpdate>.makeStream()
    }

    func emit(_ update: LiveTranscriptUpdate) { continuation.yield(update) }

    func prepare(language: TranscriptionLanguage) async throws {
        if rejects { throw LiveTranscribingError.unsupportedLanguage(language.rawValue) }
    }

    func append(samples: [Float]) { receivedSampleCount += samples.count }

    func finish() async {
        didFinish = true
        continuation.finish()
    }

    func cancel() { continuation.finish() }
}
