import XCTest

@testable import VoicePaste

/// Параметры учебного режима обязаны переживать перезапуск.
///
/// Повод для этого набора конкретный: добавив порог паузы и шаг обновления, я
/// не дописал их в `persist()`. Настройки менялись на экране и молча
/// возвращались к умолчанию при следующем запуске — отказ, который замечают
/// не сразу и списывают на «показалось».
@MainActor
final class AppSettingsLecturePersistenceTests: XCTestCase {

    private func makeDefaults() throws -> UserDefaults {
        let suite = "VoicePasteTests-LectureSettings-\(UUID().uuidString)"
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    func test_lectureLanguage_survivesANewInstance() throws {
        let defaults = try makeDefaults()
        AppSettings(defaults: defaults).lectureLanguage = .en

        XCTAssertEqual(AppSettings(defaults: defaults).lectureLanguage, .en)
    }

    func test_paragraphPause_survivesANewInstance() throws {
        let defaults = try makeDefaults()
        AppSettings(defaults: defaults).lectureParagraphPauseSeconds = 5

        XCTAssertEqual(AppSettings(defaults: defaults).lectureParagraphPauseSeconds, 5)
    }

    func test_window_survivesANewInstance() throws {
        let defaults = try makeDefaults()
        AppSettings(defaults: defaults).lectureWindowSeconds = 12

        XCTAssertEqual(AppSettings(defaults: defaults).lectureWindowSeconds, 12)
    }

    /// Язык лекции по умолчанию задан явно, а не «автоматически»: ошибка
    /// определения стоит дороже, чем один выбор руками.
    func test_lectureLanguage_defaultsToAnExplicitLanguage() throws {
        let defaults = try makeDefaults()

        XCTAssertNotEqual(AppSettings(defaults: defaults).lectureLanguage, .auto)
    }

    func test_outOfRangeValues_areClampedBeforePersisting() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)

        settings.lectureWindowSeconds = 999
        settings.lectureParagraphPauseSeconds = 0

        XCTAssertEqual(settings.lectureWindowSeconds, LectureRecorder.windowRange.upperBound)
        XCTAssertEqual(settings.lectureParagraphPauseSeconds, LectureParagraphBuilder.pauseRange.lowerBound)
        XCTAssertEqual(
            AppSettings(defaults: defaults).lectureWindowSeconds,
            LectureRecorder.windowRange.upperBound
        )
    }
}
