import XCTest

@testable import VoicePaste

/// Порядок счёта окон по ходу записи.
///
/// Живой звук здесь не нужен: тип разговаривает с записью через две
/// замыкания — «сколько накоплено» и «дай отрезок», — и с моделью через
/// протокол. Значит проверяется всё, кроме самого `AVAudioEngine`.
@MainActor
final class StreamingDictationTranscriberTests: XCTestCase {

    private let window = 100
    private let overlap = 10

    private func makeSubject(
        pollInterval: Duration = .milliseconds(5)
    ) -> StreamingDictationTranscriber {
        StreamingDictationTranscriber(
            windowSamples: window,
            overlapSamples: overlap,
            pollInterval: pollInterval
        )
    }

    private func silence(_ count: Int) -> [Float] { Array(repeating: 0, count: count) }

    // MARK: - Короткая запись

    func test_recordingShorterThanAWindow_isTranscribedInOnePass() async throws {
        let subject = makeSubject()
        let model = ScriptedTranscriber(texts: ["вся запись целиком"])

        let result = try await subject.finish(
            transcriber: model,
            language: .auto,
            totalSamples: silence(window / 2)
        )

        XCTAssertEqual(result.rawText, "вся запись целиком")
        let calls = await model.requestedSampleCounts
        XCTAssertEqual(calls, [window / 2], "Короткая запись обязана уйти в модель одним куском")
    }

    // MARK: - Длинная запись

    func test_closedWindowsAreTranscribedWhileRecordingContinues() async throws {
        let subject = makeSubject()
        let model = ScriptedTranscriber(texts: ["первое окно", "второе окно", "хвост"])
        let recorded = Counter(value: window * 2)

        subject.begin(
            transcriber: model,
            language: .auto,
            availableSamples: { recorded.value },
            readSamples: { [weak self] range in self?.silence(range.count) ?? [] }
        )
        try await waitUntil { await model.callCount >= 2 }
        subject.cancel()

        let calls = await model.requestedSampleCounts
        XCTAssertEqual(calls, [window, window], "Оба закрывшихся окна должны быть посчитаны")
    }

    func test_tailIsTranscribedOnFinish_andMergedWithTheWindows() async throws {
        let subject = makeSubject()
        // Перекрытие в два слова: одно совпавшее склейка намеренно не
        // снимает — случайное совпадение на стыке не повтор, и на это у
        // `TranscriptChunkMerger` есть собственный тест.
        let model = ScriptedTranscriber(texts: ["раз два три", "два три четыре"])
        let recorded = Counter(value: window)

        subject.begin(
            transcriber: model,
            language: .auto,
            availableSamples: { recorded.value },
            readSamples: { [weak self] range in self?.silence(range.count) ?? [] }
        )
        try await waitUntil { await model.callCount >= 1 }

        let result = try await subject.finish(
            transcriber: model,
            language: .auto,
            totalSamples: silence(window + 30)
        )

        // Склейка сняла повтор «два три» на стыке окна и хвоста.
        XCTAssertEqual(result.rawText, "раз два три четыре")
    }

    func test_languageIsTakenFromTheFirstWindowAndKept() async throws {
        let subject = makeSubject()
        let model = ScriptedTranscriber(
            texts: ["первое", "второе"],
            languages: ["ru", "en"]
        )
        let recorded = Counter(value: window)

        subject.begin(
            transcriber: model,
            language: .auto,
            availableSamples: { recorded.value },
            readSamples: { [weak self] range in self?.silence(range.count) ?? [] }
        )
        try await waitUntil { await model.callCount >= 1 }

        let result = try await subject.finish(
            transcriber: model,
            language: .auto,
            totalSamples: silence(window + 30)
        )

        XCTAssertEqual(result.detectedLanguage, "ru", "Язык не должен меняться внутри одной записи")
    }

    // MARK: - Отказ и отмена

    /// Отказ окна не стоит целой диктовки: считанное выбрасывается, запись
    /// уходит в модель одним проходом.
    func test_windowFailure_fallsBackToASingleWholeBufferPass() async throws {
        let subject = makeSubject()
        let model = ScriptedTranscriber(texts: [], failFirst: true, thenTexts: ["запись целиком"])
        let recorded = Counter(value: window)

        subject.begin(
            transcriber: model,
            language: .auto,
            availableSamples: { recorded.value },
            readSamples: { [weak self] range in self?.silence(range.count) ?? [] }
        )
        try await waitUntil { await model.callCount >= 1 }

        let total = window + 30
        let result = try await subject.finish(
            transcriber: model,
            language: .auto,
            totalSamples: silence(total)
        )

        XCTAssertEqual(result.rawText, "запись целиком")
        let calls = await model.requestedSampleCounts
        XCTAssertEqual(calls.last, total, "Откат обязан отдать модели всю запись, а не хвост")
    }

    func test_cancelDiscardsEverythingAlreadyTranscribed() async throws {
        let subject = makeSubject()
        let model = ScriptedTranscriber(texts: ["посчитанное окно", "после отмены"])
        let recorded = Counter(value: window)

        subject.begin(
            transcriber: model,
            language: .auto,
            availableSamples: { recorded.value },
            readSamples: { [weak self] range in self?.silence(range.count) ?? [] }
        )
        try await waitUntil { await model.callCount >= 1 }
        subject.cancel()

        let result = try await subject.finish(
            transcriber: model,
            language: .auto,
            totalSamples: silence(window / 2)
        )

        XCTAssertEqual(
            result.rawText, "после отмены",
            "Отменённая запись не оставляет следов: прежний текст не должен всплыть"
        )
    }

    // MARK: - Вспомогательное

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Условие не наступило за \(timeout)")
    }
}

/// Модель, отвечающая по списку: каждое обращение забирает следующий ответ.
/// `MockTranscriber` для этого не годится — он всегда отдаёт одно и то же, а
/// здесь важно отличить окна друг от друга и от хвоста.
private actor ScriptedTranscriber: Transcribing {
    private var texts: [String]
    private var languages: [String]
    private var failFirst: Bool
    private(set) var requestedSampleCounts: [Int] = []

    var callCount: Int { requestedSampleCounts.count }

    init(
        texts: [String],
        languages: [String] = [],
        failFirst: Bool = false,
        thenTexts: [String] = []
    ) {
        self.texts = texts + thenTexts
        self.languages = languages
        self.failFirst = failFirst
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        requestedSampleCounts.append(request.samples.count)
        if failFirst {
            failFirst = false
            throw TranscribingError.underlying("окно не посчиталось")
        }
        let text = texts.isEmpty ? "" : texts.removeFirst()
        let language = languages.isEmpty ? nil : languages.removeFirst()
        return TranscriptionResult(rawText: text, detectedLanguage: language)
    }
}

/// Счётчик накопленных сэмплов. Замыкания записи вызываются с главного
/// актора, поэтому хватает простого класса.
@MainActor
private final class Counter {
    var value: Int
    init(value: Int) { self.value = value }
}
