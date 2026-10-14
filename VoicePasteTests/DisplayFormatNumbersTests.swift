import Testing

@testable import VoicePaste

/// Числа в интерфейсе: склонение и одна форма длительности на всех экранах.
@Suite("Числа в интерфейсе")
struct DisplayFormatNumbersTests {

    @Test("слово склоняется по правилам русского", arguments: [
        (0, "0 слов"), (1, "1 слово"), (2, "2 слова"), (4, "4 слова"), (5, "5 слов"),
        (11, "11 слов"), (12, "12 слов"), (21, "21 слово"), (22, "22 слова"), (111, "111 слов"), (412, "412 слов"),
    ])
    func wordsArePluralised(count: Int, expected: String) {
        #expect(DisplayFormat.words(count) == expected)
    }

    @Test("расшифровка склоняется по правилам русского", arguments: [
        (1, "1 расшифровка"), (3, "3 расшифровки"), (7, "7 расшифровок"), (21, "21 расшифровка"),
    ])
    func transcriptionsArePluralised(count: Int, expected: String) {
        #expect(DisplayFormat.transcriptions(count) == expected)
    }

    @Test("длительность: секунды, минуты и часы с единицами", arguments: [
        (0, "0 с"), (6_000, "6 с"), (59_000, "59 с"), (60_000, "1 мин"), (95_000, "1 мин 35 с"),
        (600_000, "10 мин"), (2_760_000, "46 мин"), (3_600_000, "1 ч"), (4_320_000, "1 ч 12 мин"),
    ])
    func durationHasUnits(milliseconds: Int, expected: String) {
        #expect(DisplayFormat.duration(milliseconds: milliseconds) == expected)
    }

    @Test("день без записей назван прямо")
    func emptyDayIsSaidPlainly() {
        let text = DisplayFormat.dayUsage(dateText: "3 окт.", words: 0, transcriptions: 0, durationMilliseconds: 0)
        #expect(text == "3 окт. · Нет записей")
    }

    @Test("день с записями — слова, расшифровки, время речи")
    func dayWithRecordsShowsTotals() {
        let text = DisplayFormat.dayUsage(dateText: "13 окт.", words: 31, transcriptions: 3, durationMilliseconds: 24_000)
        #expect(text == "13 окт. · 31 слово · 3 расшифровки · 24 с")
    }
}
