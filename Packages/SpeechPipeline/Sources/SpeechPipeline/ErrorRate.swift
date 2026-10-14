import Foundation

/// Доля ошибок распознавания: расстояние Левенштейна по словам или знакам,
/// делённое на длину эталона.
nonisolated public enum ErrorRate {

    public static func words(reference: String, hypothesis: String) -> Double {
        rate(tokens(reference, byCharacter: false), tokens(hypothesis, byCharacter: false))
    }

    public static func characters(reference: String, hypothesis: String) -> Double {
        rate(tokens(reference, byCharacter: true), tokens(hypothesis, byCharacter: true))
    }

    private static func tokens(_ text: String, byCharacter: Bool) -> [String] {
        let cleaned = text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .unicodeScalars
            .map { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) ? Character($0) : " " }
        let normalized = String(cleaned)
        if byCharacter {
            return normalized.filter { $0 != " " }.map(String.init)
        }
        return normalized.split(separator: " ").map(String.init)
    }

    private static func rate(_ reference: [String], _ hypothesis: [String]) -> Double {
        guard !reference.isEmpty else { return hypothesis.isEmpty ? 0 : 1 }
        var previous = Array(0...hypothesis.count)
        for (i, expected) in reference.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: hypothesis.count)
            for (j, actual) in hypothesis.enumerated() {
                let substitution = previous[j] + (expected == actual ? 0 : 1)
                current[j + 1] = min(substitution, previous[j + 1] + 1, current[j] + 1)
            }
            previous = current
        }
        return Double(previous[hypothesis.count]) / Double(reference.count)
    }
}
