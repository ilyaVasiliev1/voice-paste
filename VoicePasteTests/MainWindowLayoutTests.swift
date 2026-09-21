import XCTest

@testable import VoicePaste

/// Инвариант «Минимум главного окна вмещает все три его колонки».
///
/// Числа раскладки — чистые константы, поэтому проверяются без поднятия
/// интерфейса. Это единственный способ получить здесь доказательство: слой
/// SwiftUI в проекте не тестируется, и раскладка ломалась молча.
///
/// `@MainActor` — потому что у проекта изоляция по умолчанию главным актором
/// (`SWIFT_DEFAULT_ACTOR_ISOLATION`), и константы раскладки наследуют её.
@MainActor
final class MainWindowLayoutTests: XCTestCase {

    private let columnsAtMinimum = MainWindowLayout.sidebarMinWidth
        + MainWindowLayout.listMinWidth
        + MainWindowLayout.detailMinWidth

    func test_windowMinimumWidth_fitsAllThreeColumnsAtTheirMinimums() {
        XCTAssertGreaterThanOrEqual(
            MainWindowLayout.windowMinWidth,
            columnsAtMinimum,
            """
            Минимум окна \(MainWindowLayout.windowMinWidth) меньше суммы колонок \(columnsAtMinimum). \
            В таком окне детали некуда сжиматься, и раскладка ломается.
            """
        )
    }

    func test_defaultWidth_fitsExpandedSidebarAndListBesideDetailMinimum() {
        let required = MainWindowLayout.sidebarMaxWidth
            + MainWindowLayout.listMaxWidth
            + MainWindowLayout.detailMinWidth

        XCTAssertGreaterThanOrEqual(
            MainWindowLayout.defaultWindowWidth,
            required,
            """
            Ширина по умолчанию \(MainWindowLayout.defaultWindowWidth) не вмещает \
            раскрытые разделы и список рядом с деталью (\(required)).
            """
        )
    }

    func test_columnWidths_areOrderedMinIdealMax() {
        XCTAssertLessThanOrEqual(MainWindowLayout.sidebarMinWidth, MainWindowLayout.sidebarIdealWidth)
        XCTAssertLessThanOrEqual(MainWindowLayout.sidebarIdealWidth, MainWindowLayout.sidebarMaxWidth)
        XCTAssertLessThanOrEqual(MainWindowLayout.listMinWidth, MainWindowLayout.listIdealWidth)
        XCTAssertLessThanOrEqual(MainWindowLayout.listIdealWidth, MainWindowLayout.listMaxWidth)
    }

    /// Минимум окна обязан оставаться выведенным, а не вписанным: вписанное
    /// руками число и есть тот дефект, который этот инвариант закрывает.
    func test_windowMinimumWidth_isDerivedFromColumns_notAStandaloneNumber() {
        XCTAssertEqual(MainWindowLayout.windowMinWidth, columnsAtMinimum)
    }
}
