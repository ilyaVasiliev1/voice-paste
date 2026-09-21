import Foundation

/// Снимает выдуманные Whisper строки-титры о субтитрах.
///
/// Модель учили на видео, где в конце идут титры переводчиков, и на музыке
/// или тишине она их «вспоминает»: «Субтитры делал DimaTorzok», «Редактор
/// субтитров …». Это не речь. В отличие от концевого наполнителя
/// (`TrailingHallucinationFilter`), такая строка встречается и в середине
/// записи, поэтому снимается где угодно.
nonisolated public enum SubtitleCreditFilter {

    /// Строка-титр: слово о субтитрах рядом со словом о том, кто их делал, или
    /// подпись известного сервиса субтитров. Одно слово «субтитры» признаком
    /// не считается — его можно сказать.
    private static let patterns: [NSRegularExpression] = [
        #"субтитр\w*\s+(делал|сделал|создавал|создал|подготовил|подготовила|перевёл|перевел)"#,
        #"(редактор|корректор|автор|переводчик)\w*\s+субтитр"#,
        #"subtitles\s+by"#,
        #"amara\.org"#,
    ].map { pattern in
        // Шаблоны постоянны; неверный — ошибка программиста, а не данных.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    public static func isCredit(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return patterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    /// Убирает из готового текста куски, которые были сегментами-титрами.
    public static func removingCredits(from text: String, segmentTexts: [String]) -> String {
        segmentTexts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && isCredit($0) }
            .reduce(text) { result, credit in result.replacingOccurrences(of: credit, with: "") }
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
