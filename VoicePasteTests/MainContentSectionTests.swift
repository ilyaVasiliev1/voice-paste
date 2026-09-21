import XCTest

@testable import VoicePaste

/// Требование «Главное окно — разделы, список и деталь».
///
/// Порядок и подписи разделов — чистые данные, поэтому проверяются без
/// поднятия интерфейса. Вид проверяется снимками (`scripts/snapshots.sh`).
@MainActor
final class MainContentSectionTests: XCTestCase {

    func test_sidebar_listsFourSectionsInAgreedOrder_withWordLabels() {
        XCTAssertEqual(MainContentSection.sidebarOrder, [.lecture, .history, .importQueue, .dashboard])
        XCTAssertEqual(
            MainContentSection.sidebarOrder.map(\.title),
            ["Лекции", "История", "Импорт", "Статистика"],
            "Подпись раздела — слово, а не ключ локализации и не пустая строка."
        )
    }

    func test_statisticsPeriods_areTodayWeekMonth() {
        XCTAssertEqual(StatisticsPeriod.allCases.map(\.dayCount), [1, 7, 30])
        XCTAssertEqual(StatisticsPeriod.allCases.map(\.title), ["Сегодня", "7 дней", "30 дней"])
    }
}
