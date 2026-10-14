import Foundation
import Testing

@testable import VoicePaste

/// Язык диктовки: что пишется в журнал и с чего начинается чистая установка.
///
/// Основание — история владельца (14.10.2026): на русской речи метка языка
/// оказывалась `en`, и такие записи кончались «Thank you». Журнал должен
/// показывать это сразу, без текста расшифровки.
@MainActor
@Suite("Язык диктовки")
struct DictationLanguageTests {

    // MARK: - Запись журнала

    @Test("запись называет режим, определённый язык и долю кириллицы")
    func entryNamesModeDetectedLanguageAndScript() {
        let detail = DictationLanguageJournal.detail(
            mode: .auto,
            detected: "en",
            text: "Это обычная русская диктовка с одним словом API.",
            durationMilliseconds: 12_500
        )

        #expect(detail.contains("mode=auto"))
        #expect(detail.contains("detected=en"))
        #expect(detail.contains("durationMs=12500"))
        #expect(detail.contains("cyrillicPercent=9") || detail.contains("cyrillicPercent=100"))
    }

    @Test("латинская концовка после русской речи видна в записи")
    func latinTailAfterCyrillicSpeechIsVisible() {
        let detail = DictationLanguageJournal.detail(
            mode: .auto,
            detected: "en",
            text: "Привет, это проверка записи. Thank you.",
            durationMilliseconds: 6_000
        )

        #expect(detail.contains("lastSentence=latin"))
    }

    @Test("русская концовка помечается кириллицей")
    func cyrillicTailIsMarkedCyrillic() {
        let detail = DictationLanguageJournal.detail(
            mode: .ru,
            detected: "ru",
            text: "Первое предложение. Второе предложение.",
            durationMilliseconds: 4_000
        )

        #expect(detail.contains("lastSentence=cyrillic"))
        #expect(detail.contains("cyrillicPercent=100"))
    }

    @Test("язык не определён и текста нет")
    func missingLanguageAndEmptyText() {
        let detail = DictationLanguageJournal.detail(
            mode: .auto,
            detected: nil,
            text: "",
            durationMilliseconds: 800
        )

        #expect(detail.contains("detected=none"))
        #expect(detail.contains("cyrillicPercent=0"))
        #expect(detail.contains("lastSentence=none"))
    }

    @Test("в запись не попадает ни слова из текста")
    func entryNeverCarriesTheText() {
        let text = "Секретный пароль от сейфа и номер карты"
        let detail = DictationLanguageJournal.detail(
            mode: .auto,
            detected: "ru",
            text: text,
            durationMilliseconds: 3_000
        )

        for word in text.split(separator: " ") {
            #expect(!detail.contains(word), "в журнале слово «\(word)»")
        }
    }

    // MARK: - Значение по умолчанию

    @Test("чистая установка начинает с русского")
    func freshInstallPinsRussian() throws {
        let defaults = try #require(UserDefaults(suiteName: "DictationLanguage-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)

        #expect(settings.languageMode == .ru)
    }

    @Test("сохранённое «автоматически» не перезаписывается")
    func storedAutoIsKept() throws {
        let defaults = try #require(UserDefaults(suiteName: "DictationLanguage-\(UUID().uuidString)"))
        defaults.set("auto", forKey: "languageMode")

        #expect(AppSettings(defaults: defaults).languageMode == .auto)
    }

    @Test("нераспознанное сохранённое значение возвращает русский")
    func unrecognisedStoredValueFallsBackToRussian() throws {
        let defaults = try #require(UserDefaults(suiteName: "DictationLanguage-\(UUID().uuidString)"))
        defaults.set("klingon", forKey: "languageMode")

        #expect(AppSettings(defaults: defaults).languageMode == .ru)
    }
}
