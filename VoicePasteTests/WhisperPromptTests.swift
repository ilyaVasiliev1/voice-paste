import Foundation
import Testing

@testable import VoicePaste

/// Подсказка-образец для модели: пунктуированный текст перед распознаванием
/// подталкивает её писать со знаками. Здесь — только сборка токенов; как она
/// влияет на текст, измерено отдельно на записи (`docs/status.md`).
@Suite("Подсказка-образец для модели")
struct WhisperPromptTests {

    /// Подставной кодировщик: слово — один токен с номером по длине, пробел перед
    /// словом виден как отдельный токен 1, спецсимвол 50_000 — «служебный».
    private static func encode(_ text: String) -> [Int] {
        text.split(separator: " ", omittingEmptySubsequences: false).flatMap { word -> [Int] in
            word.isEmpty ? [1] : [word == "<s>" ? 50_000 : word.count]
        }
    }

    @Test("пустая подсказка — токенов нет")
    func emptyPromptGivesNoTokens() {
        #expect(WhisperPrompt.tokens(for: "  \n ", encode: Self.encode, specialTokenBegin: 50_000) == nil)
    }

    @Test("перед текстом ставится пробел, по краям лишнее срезается")
    func leadingSpaceIsAddedAndEdgesTrimmed() {
        let tokens = WhisperPrompt.tokens(for: "  да нет  ", encode: Self.encode, specialTokenBegin: 50_000)
        // " да нет" → пустое слово перед первым пробелом, затем «да» (2) и «нет» (3).
        #expect(tokens == [1, 2, 3])
    }

    @Test("служебные токены в подсказку не попадают")
    func specialTokensAreFiltered() {
        let tokens = WhisperPrompt.tokens(for: "да <s> нет", encode: Self.encode, specialTokenBegin: 50_000)
        #expect(tokens == [1, 2, 3])
    }

    @Test("образец для русского содержит запятую и точку, для остальных — нет подсказки")
    func sampleExistsOnlyForRussian() {
        let russian = WhisperPrompt.sample(forLanguageCode: "ru")
        #expect(russian?.contains(",") == true)
        #expect(russian?.contains(".") == true)
        #expect(WhisperPrompt.sample(forLanguageCode: "zh") == nil)
        #expect(WhisperPrompt.sample(forLanguageCode: nil) == nil)
    }
}
