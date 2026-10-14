import Foundation
import Testing

@testable import VoicePaste

/// Общие шаги диктовки, импорта и учебного режима: склейка окон и приведение
/// текста. Раньше у каждого входа была своя копия склейки.
@Suite("Склейка окон и завершение текста")
struct TranscriptAccumulatorTests {

    private struct NoSpellChecker: SpellChecking {
        func misspelledRanges(in text: String, language: String) -> [Range<String.Index>]? { nil }
        func guesses(forWordRange range: Range<String.Index>, in text: String, language: String) -> [String] { [] }
    }

    @Test("пустой накопитель отдаёт пустой текст и язык не определён")
    func emptyAccumulator() {
        let result = TranscriptAccumulator().result
        #expect(result.rawText.isEmpty)
        #expect(result.detectedLanguage == nil)
    }

    @Test("повтор на стыке окон снимается")
    func overlapIsRemoved() {
        var accumulator = TranscriptAccumulator()
        accumulator.append(TranscriptionResult(rawText: "раз два три", detectedLanguage: "ru"))
        accumulator.append(TranscriptionResult(rawText: "два три четыре", detectedLanguage: "ru"))
        #expect(accumulator.result.rawText == "раз два три четыре")
    }

    @Test("язык берётся из первого окна, у которого он определён, и дальше не меняется")
    func languageIsTakenFromFirstWindowThatHasOne() {
        var accumulator = TranscriptAccumulator()
        accumulator.append(TranscriptionResult(rawText: "а", detectedLanguage: nil))
        accumulator.append(TranscriptionResult(rawText: "б", detectedLanguage: "ru"))
        accumulator.append(TranscriptionResult(rawText: "в", detectedLanguage: "en"))
        #expect(accumulator.result.detectedLanguage == "ru")
    }

    @Test("завершение приводит текст и переносит длительность и язык")
    func finishNormalizesAndCarriesMetadata() async {
        let pipeline = DictationPipeline(normalizer: TextNormalizer(spellChecker: NoSpellChecker()))
        let draft = await pipeline.finish(
            TranscriptionResult(rawText: "  Привет ,  мир  ", detectedLanguage: "ru"),
            language: .ru,
            vocabulary: [],
            autoCorrectSafeTypos: false,
            durationMilliseconds: 4_200
        )
        #expect(draft.text == "Привет, мир")
        #expect(draft.rawText == "  Привет ,  мир  ")
        #expect(draft.detectedLanguage == "ru")
        #expect(draft.durationMilliseconds == 4_200)
    }
}
