import AppKit
import Foundation

/// `NSSpellChecker`-backed implementation used at runtime.
nonisolated public struct NSSpellCheckerAdapter: SpellChecking {
    public init() {}

    nonisolated public func misspelledRanges(in text: String, language: String) -> [Range<String.Index>]? {
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

    nonisolated public func guesses(forWordRange range: Range<String.Index>, in text: String, language: String) -> [String] {
        let nsRange = NSRange(range, in: text)
        return NSSpellChecker.shared.guesses(
            forWordRange: nsRange,
            in: text,
            language: language,
            inSpellDocumentWithTag: 0
        ) ?? []
    }
}
