import Foundation

/// Снимает служебную разметку модели с распознанного текста.
///
/// Whisper размечает поток собственными токенами — начало расшифровки, язык,
/// режим, метки времени: `<|startoftranscript|>`, `<|ru|>`, `<|transcribe|>`,
/// `<|0.00|>`, `<|endoftext|>`. В готовом тексте результата их нет, но в
/// тексте **отдельных сегментов** они остаются, и без очистки едут прямо на
/// экран — ровно это и случилось с учебным режимом.
///
/// Собственный помощник WhisperKit (`Constants.specialTokenCharacters`) здесь
/// не годится: он обрезает символы `<`, `|`, `>` по краям строки, а разметка
/// стоит и в середине.
nonisolated public enum WhisperSpecialTokens {

    /// Любой токен вида `<|что-угодно|>`.
    private static let pattern = try? NSRegularExpression(pattern: "<\\|[^|]*\\|>")

    /// Текст без служебных токенов и лишних пробелов после них.
    public static func strip(_ text: String) -> String {
        guard let pattern else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let cleaned = pattern.stringByReplacingMatches(
            in: text, range: range, withTemplate: " "
        )
        // Удалённый токен оставляет после себя двойные пробелы, а на стыке
        // сегментов — пробел перед знаком препинания.
        return cleaned
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " ([,.!?;:…»)])", with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
