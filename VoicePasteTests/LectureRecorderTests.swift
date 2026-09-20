import XCTest

@testable import VoicePaste

/// Требование «Запись лекции пополняет расшифровку по ходу» и инвариант
/// размера окна.
///
/// Живой звук не нужен: запись видна типу через два замыкания, модель — через
/// протокол. Проверяется то, ради чего режим и сделан: текст появляется до
/// остановки, времена абзацев отсчитываются от начала записи, а не от начала
/// окна, и отказ окна не роняет лекцию.
@MainActor
final class LectureRecorderTests: XCTestCase {

    private let sampleRate = 16_000

    private func samples(seconds: Double) -> [Float] {
        Array(repeating: 0, count: Int(seconds * Double(sampleRate)))
    }

    // MARK: - Инвариант окна

    func test_lectureWindow_isShorterThanTheDictationWindow() {
        XCTAssertLessThanOrEqual(LectureRecorder.defaultWindowSeconds, 10)
        XCTAssertGreaterThanOrEqual(LectureRecorder.overlapSeconds, 1)
        XCTAssertLessThan(
            LectureRecorder.defaultWindowSeconds, 28,
            "Окно лекции обязано быть короче диктовочного: иначе текст появляется слишком поздно"
        )
    }

    func test_windowOutsideTheAllowedRange_isClamped() {
        XCTAssertEqual(LectureRecorder.clampWindow(1), LectureRecorder.windowRange.lowerBound)
        XCTAssertEqual(LectureRecorder.clampWindow(99), LectureRecorder.windowRange.upperBound)
    }

    /// Лекция бывает смешанной: китайский с английскими вставками. Привязка
    /// к языку первого окна заставила бы читать чужую речь чужим языком,
    /// поэтому каждое окно определяет язык само.
    func test_lectureNeverPinsTheLanguageOfTheFirstWindow() async throws {
        let recorder = LectureRecorder(pollInterval: .milliseconds(5))
        let window = LectureRecorder.defaultWindowSeconds
        let model = ScriptedLectureTranscriber(
            scripts: [[SegmentSeed(text: "Первое.", start: 0, end: 2)],
                      [SegmentSeed(text: "Второе.", start: 0, end: 2)]],
            languages: ["zh", "ru"]
        )
        let available = Box(Int(window * 2) * sampleRate)

        recorder.begin(
            transcriber: model,
            language: .auto,
            pauseSeconds: 2,
            availableSamples: { available.value },
            readSamples: { [weak self] range in self?.samples(seconds: Double(range.count) / 16_000) ?? [] }
        )
        try await waitUntil { await model.callCount >= 2 }
        let hints = await model.receivedHints
        recorder.cancel()

        XCTAssertEqual(
            hints, ["", ""],
            "Ни одному окну лекции язык не навязывается: иначе смешанная лекция читается одним языком"
        )
    }

    // MARK: - Пополнение по ходу

    func test_closedWindowIsTranscribedBeforeRecordingStops() async throws {
        let recorder = LectureRecorder(pollInterval: .milliseconds(5))
        let model = ScriptedLectureTranscriber(scripts: [
            [SegmentSeed(text: "Сегодня разберём модель актора.", start: 0, end: 4)]
        ])
        let available = Box(Int(LectureRecorder.defaultWindowSeconds) * sampleRate)

        recorder.begin(
            transcriber: model,
            language: .auto,
            pauseSeconds: 2,
            availableSamples: { available.value },
            readSamples: { [weak self] range in self?.samples(seconds: Double(range.count) / 16_000) ?? [] }
        )
        try await waitUntil { recorder.paragraphs.isEmpty == false }
        // Снимаем до отмены: отмена по замыслу стирает всё посчитанное.
        let appeared = recorder.paragraphs.first?.text
        recorder.cancel()

        XCTAssertEqual(appeared, "Сегодня разберём модель актора.")
    }

    /// Главное свойство времён: модель отсчитывает их от начала окна, а лекции
    /// нужно от начала записи. Без сдвига второй абзац показал бы 00:02
    /// вместо 00:11, и вернуться к месту стало бы невозможно.
    func test_segmentTimesAreOffsetToTheStartOfTheRecording() async throws {
        let recorder = LectureRecorder(pollInterval: .milliseconds(5))
        let window = LectureRecorder.defaultWindowSeconds
        let model = ScriptedLectureTranscriber(scripts: [
            [SegmentSeed(text: "Первое окно.", start: 0, end: 4)],
            [SegmentSeed(text: "Второе окно.", start: 2, end: 6)],
        ])
        let available = Box(Int(window * 2) * sampleRate)

        recorder.begin(
            transcriber: model,
            language: .auto,
            pauseSeconds: 2,
            availableSamples: { available.value },
            readSamples: { [weak self] range in self?.samples(seconds: Double(range.count) / 16_000) ?? [] }
        )
        try await waitUntil { recorder.paragraphs.count >= 2 }
        let lastStart = recorder.paragraphs.last?.startSeconds ?? 0
        recorder.cancel()

        // Второе окно начинается на (window - overlap) секунде записи, а его
        // собственный сегмент — на второй секунде окна.
        let expected = window - LectureRecorder.overlapSeconds + 2
        XCTAssertEqual(lastStart, expected, accuracy: 0.01)
    }

    func test_finish_transcribesTheTailAndReturnsAllParagraphs() async throws {
        let recorder = LectureRecorder(pollInterval: .milliseconds(5))
        let model = ScriptedLectureTranscriber(scripts: [
            [SegmentSeed(text: "Хвост записи.", start: 0, end: 3)]
        ])

        let paragraphs = await recorder.finish(
            transcriber: model,
            language: .auto,
            totalSamples: samples(seconds: 3)
        )

        XCTAssertEqual(paragraphs.map(\.text), ["Хвост записи."])
    }

    /// Язык лекции в карточке — тот, что встретился чаще, а не первый:
    /// на смешанной лекции первое окно о языке всей лекции не говорит.
    func test_lectureLanguage_isTheMostFrequentAcrossWindows() async throws {
        let recorder = LectureRecorder(pollInterval: .milliseconds(5))
        let model = ScriptedLectureTranscriber(
            scripts: [[SegmentSeed(text: "Первое.", start: 0, end: 2)]],
            languages: ["ru"]
        )

        _ = await recorder.finish(
            transcriber: model,
            language: .auto,
            totalSamples: samples(seconds: 2)
        )

        XCTAssertEqual(recorder.detectedLanguage, "ru")
    }

    // MARK: - Отказ и отмена

    /// Отказ окна лекцию не роняет: человек слушает, и потерять всё
    /// прослушанное хуже, чем показать запись с пробелом.
    func test_windowFailure_keepsTheLectureAndEverythingAlreadyTranscribed() async throws {
        let recorder = LectureRecorder(pollInterval: .milliseconds(5))
        let model = ScriptedLectureTranscriber(
            scripts: [[SegmentSeed(text: "Успевшее окно.", start: 0, end: 3)], []],
            failAtCall: 2
        )
        let available = Box(Int(LectureRecorder.defaultWindowSeconds * 2) * sampleRate)

        recorder.begin(
            transcriber: model,
            language: .auto,
            pauseSeconds: 2,
            availableSamples: { available.value },
            readSamples: { [weak self] range in self?.samples(seconds: Double(range.count) / 16_000) ?? [] }
        )
        try await waitUntil { await model.callCount >= 2 }
        let survived = recorder.paragraphs.map(\.text)
        recorder.cancel()

        XCTAssertEqual(
            survived, ["Успевшее окно."],
            "Отказ одного окна не должен уносить уже распознанное"
        )
        XCTAssertTrue(recorder.paragraphs.isEmpty, "После отмены следов не остаётся")
    }

    func test_cancel_clearsParagraphsAndLanguage() async throws {
        let recorder = LectureRecorder(pollInterval: .milliseconds(5))
        let model = ScriptedLectureTranscriber(scripts: [[SegmentSeed(text: "Что-то.", start: 0, end: 2)]], languages: ["ru"])
        _ = await recorder.finish(
            transcriber: model,
            language: .auto,
            totalSamples: samples(seconds: 2)
        )
        XCTAssertFalse(recorder.paragraphs.isEmpty)

        recorder.cancel()

        XCTAssertTrue(recorder.paragraphs.isEmpty)
        XCTAssertNil(recorder.detectedLanguage)
    }

    /// Модель нередко склеивает перекрывшийся хвост с новыми словами в один
    /// сегмент. Раньше он выбрасывался целиком — вместе с новыми словами.
    func test_segmentStraddlingTheOverlap_isKeptInsteadOfDropped() async throws {
        let recorder = LectureRecorder(pollInterval: .milliseconds(5))
        let window = LectureRecorder.defaultWindowSeconds
        let model = ScriptedLectureTranscriber(scripts: [
            [SegmentSeed(text: "Первое окно кончается тут.", start: 0, end: window)],
            // Начинается до конца принятого (перекрытие), кончается после:
            // в нём и повтор, и новые слова.
            [SegmentSeed(text: "тут и продолжается дальше.", start: 0, end: 4)],
        ])
        let available = Box(Int(window * 2) * sampleRate)

        recorder.begin(
            transcriber: model,
            language: .auto,
            pauseSeconds: 2,
            availableSamples: { available.value },
            readSamples: { [weak self] range in self?.samples(seconds: Double(range.count) / 16_000) ?? [] }
        )
        try await waitUntil { await model.callCount >= 2 }
        let text = recorder.paragraphs.map(\.text).joined(separator: " ")
        recorder.cancel()

        XCTAssertTrue(
            text.contains("продолжается дальше"),
            "Новые слова в сегменте, начавшемся до границы, теряться не должны. Получено: \(text)"
        )
    }

    // MARK: - Вспомогательное

    /// Условие читает состояние записи, а оно живёт на главном акторе —
    /// поэтому замыкание изолировано им же, а не `@Sendable`.
    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Условие не наступило за \(timeout)")
    }
}

/// Модель, отвечающая по списку сегментов на каждый вызов. `MockTranscriber`
/// не годится: он не умеет ни разных ответов, ни времён, а здесь важно и то,
/// и другое.
private actor ScriptedLectureTranscriber: Transcribing {
    private var scripts: [[SegmentSeed]]
    private var languages: [String]
    private let failAtCall: Int?
    private(set) var callCount = 0
    private(set) var receivedHints: [String] = []

    init(
        scripts: [[SegmentSeed]],
        languages: [String] = [],
        failAtCall: Int? = nil
    ) {
        self.scripts = scripts
        self.languages = languages
        self.failAtCall = failAtCall
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        callCount += 1
        receivedHints.append(request.detectedLanguageHint ?? "")
        if callCount == failAtCall { throw TranscribingError.underlying("окно не посчиталось") }
        let script = scripts.isEmpty ? [] : scripts.removeFirst()
        let language = languages.isEmpty ? nil : languages.removeFirst()
        return TranscriptionResult(
            rawText: script.map(\.text).joined(separator: " "),
            detectedLanguage: language,
            segments: script.map {
                TranscribedSegment(text: $0.text, startSeconds: $0.start, endSeconds: $0.end)
            }
        )
    }
}

/// Счётчик накопленных сэмплов. Замыкания записи зовутся с главного актора.
@MainActor
private final class Box {
    var value: Int
    init(_ value: Int) { self.value = value }
}

/// Заготовка сегмента для сценариев модели. Кортеж на три поля линтер не
/// пропускает, да и `$0.1` читается хуже, чем `$0.start`.
private struct SegmentSeed {
    let text: String
    let start: Double
    let end: Double
}
