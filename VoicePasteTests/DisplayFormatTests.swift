import XCTest

@testable import VoicePaste

/// Одна форма даты и названия языка на всех экранах.
final class DisplayFormatTests: XCTestCase {
    private let locale = Locale(identifier: "ru_RU")
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = locale
        return calendar
    }

    private func date(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string)!
    }

    private func text(_ record: String, now: String = "2026-10-14T12:00:00Z") -> String {
        DisplayFormat.recordDate(date(record), now: date(now), calendar: calendar, locale: locale)
    }

    func test_today_isTodayWithTime() {
        XCTAssertEqual(text("2026-10-14T09:05:00Z"), "Сегодня, 9:05")
    }

    func test_yesterday_isYesterdayWithTime() {
        XCTAssertEqual(text("2026-10-13T23:10:00Z"), "Вчера, 23:10")
    }

    func test_earlierThisYear_hasNoYear() {
        XCTAssertEqual(text("2026-08-03T17:16:00Z"), "3 авг., 17:16")
    }

    func test_previousYear_carriesTheYear_butNoTime() {
        let result = text("2025-12-31T17:16:00Z")
        XCTAssertTrue(result.contains("2025"), result)
        XCTAssertFalse(result.contains("17:16"), result)
    }

    func test_languageName_isCapitalisedAndWritten() {
        XCTAssertEqual(DisplayFormat.languageName("ru", locale: locale), "Русский")
        XCTAssertEqual(DisplayFormat.languageName("zh", locale: locale), "Китайский")
        XCTAssertNil(DisplayFormat.languageName(nil, locale: locale))
    }
}
