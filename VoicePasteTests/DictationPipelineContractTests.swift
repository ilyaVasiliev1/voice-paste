import Foundation
import Testing

@testable import VoicePaste

/// Контракт конвейера диктовки на поддельном движке: без модели, без микрофона,
/// без AppKit. Порядок и отказы здесь доказаны отдельно от `AppState`, чтобы
/// вынос координатора (срез 4) было чем ловить.
@Suite("Конвейер диктовки: контракт")
struct DictationPipelineContractTests {

    private struct NoSpellChecker: SpellChecking {
        func misspelledRanges(in text: String, language: String) -> [Range<String.Index>]? { nil }
        func guesses(forWordRange range: Range<String.Index>, in text: String, language: String) -> [String] { [] }
    }

    private final class ScriptedRecognizer: Recognizing, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private let log: EventLog
        let result: Result<TranscriptionResult, TranscribingError>

        init(log: EventLog, result: Result<TranscriptionResult, TranscribingError>) {
            self.log = log
            self.result = result
        }

        var callCount: Int { lock.withLock { calls } }

        func recognize(samples: [Float], language: TranscriptionLanguage) async throws -> TranscriptionResult {
            lock.withLock { calls += 1 }
            log.append("recognize", "\(samples.count)/\(language.rawValue)")
            return try result.get()
        }
    }

    private static let rate = 16_000

    private static func speech(seconds: Double) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { 0.1 * sin(Float($0) * 0.3) }
    }

    private static func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(rate)))
    }

    private let pipeline = DictationPipeline(normalizer: TextNormalizer(spellChecker: NoSpellChecker()))

    // MARK: - Сторож по захвату

    @Test("запись короче половины секунды отвергается до модели")
    func tooShortCaptureIsRejected() {
        #expect(pipeline.admitCapture(sampleCount: 7_999, captureRMS: 0.05) == .tooShort)
    }

    @Test("запись ниже порога шума отвергается до модели")
    func captureBelowNoiseFloorIsRejected() {
        #expect(pipeline.admitCapture(sampleCount: 16_000, captureRMS: 0.003) == .belowNoiseFloor)
    }

    @Test("запись ровно на границах проходит")
    func captureOnTheBoundaryIsAdmitted() {
        #expect(pipeline.admitCapture(sampleCount: 8_000, captureRMS: 0.004) == nil)
    }

    // MARK: - Шаги по порядку

    @Test("речь проходит: движок вызван один раз, текст приведён, длительность посчитана")
    func speechProducesNormalizedDraft() async throws {
        let log = EventLog()
        let engine = ScriptedRecognizer(
            log: log,
            result: .success(TranscriptionResult(rawText: "  Привет ,  мир  ", detectedLanguage: "ru"))
        )

        let outcome = try await pipeline.run(
            DictationInput(
                samples: Self.speech(seconds: 2),
                language: .ru,
                vocabulary: [],
                autoCorrectSafeTypos: false
            ),
            recognizer: engine,
            onSpeechConfirmed: { log.append("confirmed", "") }
        )

        guard case .draft(let draft) = outcome else {
            Issue.record("ожидался черновик, получено \(outcome)")
            return
        }
        #expect(draft.rawText == "  Привет ,  мир  ")
        #expect(draft.text == "Привет, мир")
        #expect(draft.detectedLanguage == "ru")
        #expect(draft.durationMilliseconds == 2_000)
        #expect(engine.callCount == 1)
        #expect(log.details(of: "recognize") == ["32000/ru"])
    }

    @Test("тишина отвергается как «нет речи», движок не вызывается и подтверждения нет")
    func silenceIsRejectedWithoutTheEngine() async throws {
        let log = EventLog()
        let engine = ScriptedRecognizer(
            log: log,
            result: .success(TranscriptionResult(rawText: "Thank you.", detectedLanguage: "en"))
        )

        let outcome = try await pipeline.run(
            DictationInput(
                samples: Self.silence(seconds: 2),
                language: .ru,
                vocabulary: [],
                autoCorrectSafeTypos: false
            ),
            recognizer: engine,
            onSpeechConfirmed: { log.append("confirmed", "") }
        )

        #expect(outcome == .rejected(.noSpeech))
        #expect(engine.callCount == 0)
        #expect(log.details(of: "confirmed").isEmpty)
    }

    @Test("подтверждение речи приходит раньше вызова движка")
    func confirmationPrecedesRecognition() async throws {
        let log = EventLog()
        let engine = ScriptedRecognizer(
            log: log,
            result: .success(TranscriptionResult(rawText: "Раз", detectedLanguage: "ru"))
        )

        _ = try await pipeline.run(
            DictationInput(
                samples: Self.speech(seconds: 1),
                language: .ru,
                vocabulary: [],
                autoCorrectSafeTypos: false
            ),
            recognizer: engine,
            onSpeechConfirmed: { log.append("confirmed", "") }
        )

        #expect(log.order == ["confirmed", "recognize"])
    }

    @Test("отказ движка выходит наружу, черновика нет")
    func engineFailureIsThrown() async {
        let log = EventLog()
        let engine = ScriptedRecognizer(log: log, result: .failure(.modelNotReady))

        await #expect(throws: TranscribingError.modelNotReady) {
            _ = try await pipeline.run(
                DictationInput(
                    samples: Self.speech(seconds: 1),
                    language: .ru,
                    vocabulary: [],
                    autoCorrectSafeTypos: false
                ),
                recognizer: engine,
                onSpeechConfirmed: {}
            )
        }
    }

    @Test("пустое распознавание — ошибка, а не пустой черновик")
    func blankRecognitionIsAnError() async {
        let log = EventLog()
        let engine = ScriptedRecognizer(
            log: log,
            result: .success(TranscriptionResult(rawText: "   ", detectedLanguage: "ru"))
        )

        await #expect(throws: TranscribingError.emptyAudio) {
            _ = try await pipeline.run(
                DictationInput(
                    samples: Self.speech(seconds: 1),
                    language: .ru,
                    vocabulary: [],
                    autoCorrectSafeTypos: false
                ),
                recognizer: engine,
                onSpeechConfirmed: {}
            )
        }
    }
}
