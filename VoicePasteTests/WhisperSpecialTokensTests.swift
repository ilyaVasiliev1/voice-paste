import XCTest

@testable import VoicePaste

/// Служебная разметка модели не должна доезжать до экрана.
///
/// Дефект был виден глазами: в учебном режиме текст выглядел как
/// `<|startoftranscript|><|ru|><|transcribe|><|0.00|> Всем привет!<|2.00|>`.
/// Готовый текст результата разметки не несёт, а текст отдельных сегментов —
/// несёт, и именно его читает учебный режим.
@MainActor
final class WhisperSpecialTokensTests: XCTestCase {

    func test_stripsLeadingServiceTokens() {
        let raw = "<|startoftranscript|><|ru|><|transcribe|><|0.00|> Всем привет!"

        XCTAssertEqual(WhisperSpecialTokens.strip(raw), "Всем привет!")
    }

    func test_stripsTimestampsInTheMiddle() {
        let raw = "<|0.00|> Первое.<|2.00|> <|2.00|> Второе.<|4.00|>"

        XCTAssertEqual(WhisperSpecialTokens.strip(raw), "Первое. Второе.")
    }

    func test_stripsEndOfTextMarker() {
        XCTAssertEqual(
            WhisperSpecialTokens.strip("Продолжение следует...<|5.64|><|endoftext|>"),
            "Продолжение следует..."
        )
    }

    func test_keepsChineseTextIntact() {
        let raw = "<|startoftranscript|><|zh|><|transcribe|><|0.00|>\u{4ECA}\u{5929}\u{6211}\u{4EEC}\u{5B66}\u{4E60}\u{3002}<|3.00|>"

        XCTAssertEqual(
            WhisperSpecialTokens.strip(raw),
            "\u{4ECA}\u{5929}\u{6211}\u{4EEC}\u{5B66}\u{4E60}\u{3002}"
        )
    }

    func test_removesSpaceLeftBeforePunctuation() {
        XCTAssertEqual(WhisperSpecialTokens.strip("Привет <|1.00|>, как дела?"), "Привет, как дела?")
    }

    func test_textWithoutTokens_isUnchangedApartFromTrimming() {
        XCTAssertEqual(WhisperSpecialTokens.strip("  Обычный текст.  "), "Обычный текст.")
    }

    func test_onlyTokens_yieldEmptyString() {
        XCTAssertEqual(WhisperSpecialTokens.strip("<|startoftranscript|><|endoftext|>"), "")
    }
}
