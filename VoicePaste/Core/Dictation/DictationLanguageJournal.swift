import Foundation

/// Запись журнала о языке одной диктовки.
///
/// Нужна, чтобы расхождение «метка языка — не то письмо, на котором речь»
/// было видно сразу: так выглядели записи с «Thank you» в конце (история
/// владельца, 14.10.2026). Только названия и числа — текст расшифровки в
/// журнал не попадает (`spec/readiness`, журнал без текста).
nonisolated public enum DictationLanguageJournal {

    public static func detail(
        mode: TranscriptionLanguage,
        detected: String?,
        text: String,
        durationMilliseconds: Int
    ) -> String {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let cyrillic = letters.filter(isCyrillic).count
        let percent = letters.isEmpty ? 0 : Int((Double(cyrillic) / Double(letters.count) * 100).rounded())
        return [
            "mode=\(mode.rawValue)",
            "detected=\(detected ?? "none")",
            "cyrillicPercent=\(percent)",
            "lastSentence=\(lastSentenceScript(of: text))",
            "durationMs=\(durationMilliseconds)",
        ].joined(separator: " ")
    }

    private static func isCyrillic(_ scalar: Unicode.Scalar) -> Bool {
        (0x0400...0x04FF).contains(scalar.value)
    }

    private static func lastSentenceScript(of text: String) -> String {
        let separators = CharacterSet(charactersIn: ".?!…\n")
        let sentence = text
            .components(separatedBy: separators)
            .last { piece in piece.unicodeScalars.contains { CharacterSet.letters.contains($0) } }
        guard let sentence else { return "none" }

        var hasCyrillic = false
        var hasLatin = false
        for scalar in sentence.unicodeScalars where CharacterSet.letters.contains(scalar) {
            if isCyrillic(scalar) { hasCyrillic = true } else { hasLatin = true }
        }
        switch (hasCyrillic, hasLatin) {
        case (true, true): return "mixed"
        case (true, false): return "cyrillic"
        case (false, true): return "latin"
        case (false, false): return "none"
        }
    }
}
