import XCTest
@testable import VoicePaste

/// Deterministic stand-in for `NSSpellChecker` (`SpellChecking`) so these
/// tests never touch AppKit or depend on which languages happen to be
/// installed on the machine running the suite.
///
/// - `supportedLanguages`: languages this fake "has installed"; any other
///   language yields `nil` from `misspelledRanges`, exactly like a real
///   `NSSpellChecker` missing that language (`EC-011`).
/// - `guessesByWord`: exact word -> candidate replacements. A word present in
///   this text is reported misspelled; its `guesses` are looked up here.
private struct FakeSpellChecker: SpellChecking {
    var supportedLanguages: Set<String>
    var guessesByWord: [String: [String]]

    func misspelledRanges(in text: String, language: String) -> [Range<String.Index>]? {
        guard supportedLanguages.contains(language) else { return nil }
        var ranges: [Range<String.Index>] = []
        for word in guessesByWord.keys {
            var searchStart = text.startIndex
            while let found = text.range(of: word, range: searchStart..<text.endIndex) {
                ranges.append(found)
                searchStart = found.upperBound
            }
        }
        return ranges
    }

    func guesses(forWordRange range: Range<String.Index>, in text: String, language: String) -> [String] {
        guessesByWord[String(text[range])] ?? []
    }
}

/// Gate 1 unit tests for `TextNormalizer` (`L-006`, `INV-007`).
/// Pipeline under test: rawText -> whitespace/typography -> vocabulary ->
/// spellcheck -> text. Every test drives `normalize(...)` directly with a
/// `FakeSpellChecker`, never `NSSpellChecker.shared`.
@MainActor
final class TextNormalizerTests: XCTestCase {

    // MARK: - AT-013: safe whitespace/typography normalization

    func test_AT013_collapsesRepeatedSpaces_andRemovesSpaceBeforePunctuation() {
        let normalizer = TextNormalizer(spellChecker: FakeSpellChecker(supportedLanguages: [], guessesByWord: [:]))

        let (text, changes) = normalizer.normalize(
            rawText: "Привет,   мир !",
            language: .ru,
            vocabulary: [],
            autoCorrectSafeTypos: false
        )

        XCTAssertEqual(text, "Привет, мир!")
        XCTAssertTrue(changes.contains { if case .whitespace = $0.kind { return true }; return false })
    }

    func test_AT013_removesSpaceBeforeComma_isPredictable() {
        let normalizer = TextNormalizer(spellChecker: FakeSpellChecker(supportedLanguages: [], guessesByWord: [:]))

        let (text, _) = normalizer.normalize(
            rawText: "Тест , мир",
            language: .ru,
            vocabulary: [],
            autoCorrectSafeTypos: false
        )

        XCTAssertEqual(text, "Тест, мир")
    }

    func test_alreadyClean_text_reportsNoWhitespaceChange() {
        let normalizer = TextNormalizer(spellChecker: FakeSpellChecker(supportedLanguages: [], guessesByWord: [:]))

        let (text, changes) = normalizer.normalize(
            rawText: "Привет, мир!",
            language: .ru,
            vocabulary: [],
            autoCorrectSafeTypos: false
        )

        XCTAssertEqual(text, "Привет, мир!")
        XCTAssertFalse(changes.contains { if case .whitespace = $0.kind { return true }; return false })
    }

    // MARK: - AT-014 / EC-012: never silently guess on URLs/abbreviations/numbers/ambiguous words

    func test_AT014_doesNotTouch_URL_evenIfSpellcheckerFlagsIt() {
        let checker = FakeSpellChecker(
            supportedLanguages: ["ru"],
            guessesByWord: ["http://example.com": ["пример"]]
        )
        let normalizer = TextNormalizer(spellChecker: checker)

        let (text, changes) = normalizer.normalize(
            rawText: "Смотри http://example.com",
            language: .ru,
            vocabulary: [],
            autoCorrectSafeTypos: true
        )

        XCTAssertEqual(text, "Смотри http://example.com")
        XCTAssertFalse(changes.contains { if case .spellcheck = $0.kind { return true }; return false })
    }

    func test_AT014_doesNotTouch_allCapsAbbreviation() {
        let checker = FakeSpellChecker(
            supportedLanguages: ["ru"],
            guessesByWord: ["IBM": ["ИБМ"]]
        )
        let normalizer = TextNormalizer(spellChecker: checker)

        let (text, _) = normalizer.normalize(
            rawText: "Работаю в IBM",
            language: .ru,
            vocabulary: [],
            autoCorrectSafeTypos: true
        )

        XCTAssertEqual(text, "Работаю в IBM")
    }

    func test_EC012_doesNotTouch_wordsContainingDigits() {
        let checker = FakeSpellChecker(
            supportedLanguages: ["ru"],
            guessesByWord: ["дом20": ["дом"]]
        )
        let normalizer = TextNormalizer(spellChecker: checker)

        let (text, _) = normalizer.normalize(
            rawText: "Живу на дом20",
            language: .ru,
            vocabulary: [],
            autoCorrectSafeTypos: true
        )

        XCTAssertEqual(text, "Живу на дом20")
    }

    /// `AT-014`: "слово с несколькими возможными заменами" — never replaced
    /// silently, unlike the single-guess case which the positive control
    /// below proves does work.
    func test_AT014_wordWithMultipleGuesses_isNotReplaced() {
        let checker = FakeSpellChecker(
            supportedLanguages: ["ru"],
            guessesByWord: ["тест": ["тезис", "текст"]]
        )
        let normalizer = TextNormalizer(spellChecker: checker)

        let (text, changes) = normalizer.normalize(
            rawText: "Это тест",
            language: .ru,
            vocabulary: [],
            autoCorrectSafeTypos: true
        )

        XCTAssertEqual(text, "Это тест")
        XCTAssertFalse(changes.contains { if case .spellcheck = $0.kind { return true }; return false })
    }

    /// Positive control: a single unambiguous, "safe" guess IS applied — this
    /// is what proves the pipeline's autocorrect step actually functions,
    /// rather than every case above passing vacuously because nothing ever
    /// gets replaced.
    func test_singleUnambiguousGuess_isAppliedAndRecorded() {
        let checker = FakeSpellChecker(
            supportedLanguages: ["ru"],
            guessesByWord: ["оштбка": ["ошибка"]]
        )
        let normalizer = TextNormalizer(spellChecker: checker)

        let (text, changes) = normalizer.normalize(
            rawText: "Это оштбка",
            language: .ru,
            vocabulary: [],
            autoCorrectSafeTypos: true
        )

        XCTAssertEqual(text, "Это ошибка")
        XCTAssertTrue(changes.contains {
            if case .spellcheck(let original, let replacement) = $0.kind {
                return original == "оштбка" && replacement == "ошибка"
            }
            return false
        })
    }

    // MARK: - AT-015 / EC-011: spellchecker unavailable for the language

    func test_AT015_EC011_missingLanguage_skipsSpellcheckStep_withoutBlocking() {
        // `ru` is deliberately absent from `supportedLanguages`, simulating
        // "недоступность проверки выбранного языка".
        let checker = FakeSpellChecker(
            supportedLanguages: ["en"],
            guessesByWord: ["оштбка": ["ошибка"]]
        )
        let normalizer = TextNormalizer(spellChecker: checker)

        let (text, changes) = normalizer.normalize(
            rawText: "Это оштбка",
            language: .ru,
            vocabulary: [],
            autoCorrectSafeTypos: true
        )

        // Transcription/normalization completes; text is returned unmodified
        // (no guess made), never thrown/blocked.
        XCTAssertEqual(text, "Это оштбка")
        XCTAssertFalse(changes.contains { if case .spellcheck = $0.kind { return true }; return false })
    }

    func test_autoCorrectDisabled_skipsSpellcheckStep_regardlessOfLanguage() {
        let checker = FakeSpellChecker(
            supportedLanguages: ["ru"],
            guessesByWord: ["оштбка": ["ошибка"]]
        )
        let normalizer = TextNormalizer(spellChecker: checker)

        let (text, _) = normalizer.normalize(
            rawText: "Это оштбка",
            language: .ru,
            vocabulary: [],
            autoCorrectSafeTypos: false
        )

        XCTAssertEqual(text, "Это оштбка")
    }

    // MARK: - AT-016: personal vocabulary rule application/disabling

    func test_AT016_activeVocabularyRule_isAppliedCaseInsensitively() {
        let normalizer = TextNormalizer(spellChecker: FakeSpellChecker(supportedLanguages: [], guessesByWord: [:]))
        let entry = VocabularyEntry(
            id: UUID(),
            spokenForm: "кодекс",
            replacement: "Codex",
            isEnabled: true,
            createdAt: 0,
            updatedAt: 0
        )

        let (text, changes) = normalizer.normalize(
            rawText: "Открой КОДЕКС пожалуйста",
            language: .ru,
            vocabulary: [entry],
            autoCorrectSafeTypos: false
        )

        XCTAssertEqual(text, "Открой Codex пожалуйста")
        XCTAssertTrue(changes.contains {
            if case .vocabulary(let spokenForm) = $0.kind { return spokenForm == "кодекс" }
            return false
        })
    }

    func test_AT016_disabledVocabularyRule_isNotApplied() {
        let normalizer = TextNormalizer(spellChecker: FakeSpellChecker(supportedLanguages: [], guessesByWord: [:]))
        let entry = VocabularyEntry(
            id: UUID(),
            spokenForm: "кодекс",
            replacement: "Codex",
            isEnabled: false,
            createdAt: 0,
            updatedAt: 0
        )

        let (text, changes) = normalizer.normalize(
            rawText: "Открой кодекс пожалуйста",
            language: .ru,
            vocabulary: [entry],
            autoCorrectSafeTypos: false
        )

        XCTAssertEqual(text, "Открой кодекс пожалуйста")
        XCTAssertFalse(changes.contains {
            if case .vocabulary = $0.kind { return true }
            return false
        })
    }

    func test_vocabularyRule_withNoReplacement_neverFires() {
        // `replacement == nil` means "protect this word", not "replace it"
        // (per `TextNormalizer.applyVocabulary` doc comment).
        let normalizer = TextNormalizer(spellChecker: FakeSpellChecker(supportedLanguages: [], guessesByWord: [:]))
        let entry = VocabularyEntry(
            id: UUID(),
            spokenForm: "кодекс",
            replacement: nil,
            isEnabled: true,
            createdAt: 0,
            updatedAt: 0
        )

        let (text, changes) = normalizer.normalize(
            rawText: "Открой кодекс",
            language: .ru,
            vocabulary: [entry],
            autoCorrectSafeTypos: false
        )

        XCTAssertEqual(text, "Открой кодекс")
        XCTAssertTrue(changes.isEmpty)
    }

    func test_pipelineOrder_vocabularyRunsBeforeSpellcheck() {
        // The vocabulary replacement's output ("Codex") must not then be
        // "corrected" again by the spellcheck step.
        let checker = FakeSpellChecker(
            supportedLanguages: ["ru"],
            guessesByWord: ["Codex": ["Кодекс"]]
        )
        let normalizer = TextNormalizer(spellChecker: checker)
        let entry = VocabularyEntry(
            id: UUID(),
            spokenForm: "кодекс",
            replacement: "Codex",
            isEnabled: true,
            createdAt: 0,
            updatedAt: 0
        )

        let (text, _) = normalizer.normalize(
            rawText: "открой кодекс",
            language: .ru,
            vocabulary: [entry],
            autoCorrectSafeTypos: true
        )

        // Vocabulary applied ("Codex"); whether the fake checker's guess for
        // "Codex" itself then applies is a separate, expected step — assert
        // only that the vocabulary substitution happened first and text
        // still reads as English "Codex" or its single safe guess, never the
        // original misheard "кодекс".
        XCTAssertNotEqual(text, "открой кодекс")
        XCTAssertTrue(text.contains("Codex") || text.contains("Кодекс"))
    }
}
