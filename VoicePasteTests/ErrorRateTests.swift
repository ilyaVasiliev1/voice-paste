import Testing

@testable import VoicePaste

/// Метрика для сравнения движков: доля ошибочных слов (для китайского — знаков)
/// после приведения к одному виду. Считается так, чтобы разные движки были сравнимы.
@Suite("Доля ошибок распознавания")
struct ErrorRateTests {

    @Test("одинаковый текст — ноль")
    func identicalIsZero() {
        #expect(ErrorRate.words(reference: "Привет, мир!", hypothesis: "привет мир") == 0)
    }

    @Test("регистр, знаки препинания и ё/е не считаются ошибкой")
    func normalizationIgnoresCaseMarksAndYo() {
        #expect(ErrorRate.words(reference: "Всё хорошо.", hypothesis: "все хорошо") == 0)
    }

    @Test("одна замена из четырёх слов — четверть")
    func oneSubstitution() {
        #expect(ErrorRate.words(reference: "раз два три четыре", hypothesis: "раз два пять четыре") == 0.25)
    }

    @Test("пропуск и вставка считаются по одной ошибке")
    func deletionAndInsertion() {
        #expect(ErrorRate.words(reference: "раз два три четыре", hypothesis: "раз два четыре") == 0.25)
        #expect(ErrorRate.words(reference: "раз два", hypothesis: "раз два три") == 0.5)
    }

    @Test("пустая гипотеза — все слова ошибочны")
    func emptyHypothesis() {
        #expect(ErrorRate.words(reference: "раз два", hypothesis: "") == 1)
    }

    @Test("пустой эталон: пусто — ноль, иначе единица на выдуманное")
    func emptyReference() {
        #expect(ErrorRate.words(reference: "", hypothesis: "") == 0)
        #expect(ErrorRate.words(reference: "", hypothesis: "Thank you") == 1)
    }

    @Test("для китайского считаются знаки, пробелы и пунктуация не в счёт")
    func charactersForChinese() {
        #expect(ErrorRate.characters(reference: "今天天气很好，", hypothesis: "今天天汽很好") == 1.0 / 6.0)
    }
}
