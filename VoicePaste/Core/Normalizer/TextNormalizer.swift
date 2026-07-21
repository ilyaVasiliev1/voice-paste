import AppKit
import Foundation

/// One deterministic change applied by the normalizer, useful for tests and
/// diagnostics (`API-local-normalizeText` returns "normalized text + applied
/// changes").
public struct NormalizationChange: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case whitespace
        case vocabulary(spokenForm: String)
        case spellcheck(original: String, replacement: String)
    }

    public let kind: Kind
}

public enum NormalizeTextError: Error, Equatable, Sendable {
    /// Never thrown for missing spellcheck language (`EC-011`); kept for
    /// protocol symmetry with `api.md`'s `spellLanguageUnavailable` — the
    /// pipeline simply skips that step instead of failing.
    case spellLanguageUnavailable
}

/// Abstraction over `NSSpellChecker` (`DEP-007`) so `TextNormalizer` is
/// pure/testable without touching AppKit in unit tests.
public protocol SpellChecking: Sendable {
    /// Ranges of `text` that look misspelled for `language`, or `nil` if
    /// spellchecking is unavailable for that language (`EC-011`).
    func misspelledRanges(in text: String, language: String) -> [Range<String.Index>]?
    /// Candidate replacements for one misspelled range. Autocorrect only
    /// applies when exactly one candidate comes back (`EC-012`, `AT-014`).
    func guesses(forWordRange range: Range<String.Index>, in text: String, language: String) -> [String]
}

/// `NSSpellChecker`-backed implementation used at runtime.
public struct NSSpellCheckerAdapter: SpellChecking {
    public init() {}

    public func misspelledRanges(in text: String, language: String) -> [Range<String.Index>]? {
        let checker = NSSpellChecker.shared
        guard !text.isEmpty else { return [] }
        guard checker.availableLanguages.contains(where: { $0.hasPrefix(language) }) else {
            return nil
        }
        var ranges: [Range<String.Index>] = []
        var searchOffset = 0
        let nsLength = (text as NSString).length
        while searchOffset < nsLength {
            let found = checker.checkSpelling(
                of: text,
                startingAt: searchOffset,
                language: language,
                wrap: false,
                inSpellDocumentWithTag: 0,
                wordCount: nil
            )
            guard found.location != NSNotFound, found.length > 0 else { break }
            if let range = Range(found, in: text) {
                ranges.append(range)
            }
            searchOffset = found.location + found.length
        }
        return ranges
    }

    public func guesses(forWordRange range: Range<String.Index>, in text: String, language: String) -> [String] {
        let nsRange = NSRange(range, in: text)
        return NSSpellChecker.shared.guesses(
            forWordRange: nsRange,
            in: text,
            language: language,
            inSpellDocumentWithTag: 0
        ) ?? []
    }
}

/// Pure, testable pipeline (`L-006`, `INV-007`): `rawText` → whitespace/
/// typography normalization → exact active vocabulary rules → safe
/// `NSSpellChecker` corrections → `text`.
public struct TextNormalizer: Sendable {
    private let spellChecker: SpellChecking

    public init(spellChecker: SpellChecking = NSSpellCheckerAdapter()) {
        self.spellChecker = spellChecker
    }

    public func normalize(
        rawText: String,
        language: TranscriptionLanguage,
        vocabulary: [VocabularyEntry],
        autoCorrectSafeTypos: Bool
    ) -> (text: String, appliedChanges: [NormalizationChange]) {
        var changes: [NormalizationChange] = []

        let whitespaceNormalized = normalizeWhitespaceAndTypography(rawText)
        if whitespaceNormalized != rawText {
            changes.append(NormalizationChange(kind: .whitespace))
        }

        let vocabularyApplied = applyVocabulary(
            text: whitespaceNormalized,
            vocabulary: vocabulary,
            changes: &changes
        )

        guard autoCorrectSafeTypos else {
            return (vocabularyApplied, changes)
        }

        let spellchecked = applySpellcheck(
            text: vocabularyApplied,
            language: language,
            changes: &changes
        )
        return (spellchecked, changes)
    }

    /// Deterministic, safe punctuation/whitespace cleanup only: collapse
    /// repeated spaces, drop space(s) before `,.!?:;`, trim ends.
    private func normalizeWhitespaceAndTypography(_ input: String) -> String {
        var result = input
        result = result.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "[ \\t]+([,.!?:;])", with: "$1", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    /// Applies only exact, whole-word, case-insensitive active vocabulary
    /// rules (`US-005`, `AT-016`); rules with an empty/nil `replacement`
    /// mean "protect this word", not "replace it", so they never fire here.
    private func applyVocabulary(
        text: String,
        vocabulary: [VocabularyEntry],
        changes: inout [NormalizationChange]
    ) -> String {
        var result = text
        for entry in vocabulary where entry.isEnabled {
            guard let replacement = entry.replacement, !replacement.isEmpty else { continue }
            guard !entry.spokenForm.isEmpty else { continue }
            let escaped = NSRegularExpression.escapedPattern(for: entry.spokenForm)
            guard let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: [.caseInsensitive]) else {
                continue
            }
            let ns = result as NSString
            let fullRange = NSRange(location: 0, length: ns.length)
            guard regex.firstMatch(in: result, range: fullRange) != nil else { continue }
            let template = NSRegularExpression.escapedTemplate(for: replacement)
            result = regex.stringByReplacingMatches(in: result, range: fullRange, withTemplate: template)
            changes.append(NormalizationChange(kind: .vocabulary(spokenForm: entry.spokenForm)))
        }
        return result
    }

    /// Applies only unambiguous single-suggestion corrections, skipping
    /// URLs/numbers/abbreviations (`EC-012`) and skipping entirely when the
    /// language has no spellchecker installed (`EC-011`).
    private func applySpellcheck(
        text: String,
        language: TranscriptionLanguage,
        changes: inout [NormalizationChange]
    ) -> String {
        let languageCode = resolvedLanguageCode(for: language)
        guard let ranges = spellChecker.misspelledRanges(in: text, language: languageCode), !ranges.isEmpty else {
            return text
        }

        var pieces: [Substring] = []
        var cursor = text.startIndex
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where range.lowerBound >= cursor {
            pieces.append(text[cursor..<range.lowerBound])
            let word = String(text[range])
            if isSafeToAutocorrect(word) {
                let guesses = spellChecker.guesses(forWordRange: range, in: text, language: languageCode)
                if guesses.count == 1, let onlyGuess = guesses.first, onlyGuess != word {
                    pieces.append(Substring(onlyGuess))
                    changes.append(NormalizationChange(kind: .spellcheck(original: word, replacement: onlyGuess)))
                } else {
                    pieces.append(text[range])
                }
            } else {
                pieces.append(text[range])
            }
            cursor = range.upperBound
        }
        pieces.append(text[cursor...])
        return pieces.joined()
    }

    private func resolvedLanguageCode(for language: TranscriptionLanguage) -> String {
        switch language {
        case .ru: return "ru"
        case .en: return "en"
        case .auto: return Locale.current.language.languageCode?.identifier ?? "en"
        }
    }

    /// `EC-012`: never silently touch URLs, numbers, or all-caps abbreviations.
    private func isSafeToAutocorrect(_ word: String) -> Bool {
        let lowered = word.lowercased()
        if lowered.hasPrefix("http") || word.contains("://") || lowered.hasPrefix("www.") { return false }
        if word.contains(where: { $0.isNumber }) { return false }
        if word.count > 1 && word == word.uppercased() { return false }
        return true
    }
}
