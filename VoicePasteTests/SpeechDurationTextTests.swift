import XCTest

@testable import VoicePaste

/// Требование «Время речи не округляется в ноль».
///
/// Три диктовки по 6–10 секунд показывались в статистике как «0 мин» —
/// расхождение с правдой, а не косметика.
@MainActor
final class SpeechDurationTextTests: XCTestCase {

    func test_underAMinute_showsSeconds_notZeroMinutes() {
        XCTAssertEqual(SpeechDurationText.text(milliseconds: 24_000), "24 с")
        XCTAssertEqual(SpeechDurationText.text(milliseconds: 59_999), "59 с")
    }

    func test_minutesAndHours_keepTheirFormat() {
        XCTAssertEqual(SpeechDurationText.text(milliseconds: 60_000), "1 мин")
        XCTAssertEqual(SpeechDurationText.text(milliseconds: 12 * 60_000 + 30_000), "12 мин")
        XCTAssertEqual(SpeechDurationText.text(milliseconds: (5 * 60 + 42) * 60_000), "5 ч 42 мин")
    }
}
