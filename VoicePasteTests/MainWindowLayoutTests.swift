import XCTest

@testable import VoicePaste

/// Инвариант «Минимум главного окна вмещает обе его колонки».
///
/// Числа раскладки — чистые константы, поэтому проверяются без поднятия
/// интерфейса. Это единственный способ получить здесь доказательство: слой
/// SwiftUI в проекте не тестируется, и раскладка ломалась молча.
///
/// `@MainActor` — потому что у проекта изоляция по умолчанию главным актором
/// (`SWIFT_DEFAULT_ACTOR_ISOLATION`), и константы раскладки наследуют её.
@MainActor
final class MainWindowLayoutTests: XCTestCase {

    func test_windowMinimumWidth_fitsSidebarAndDetailAtTheirMinimums() {
        let required = MainWindowLayout.sidebarMinWidth + MainWindowLayout.detailMinWidth

        XCTAssertGreaterThanOrEqual(
            MainWindowLayout.windowMinWidth,
            required,
            """
            Минимум окна \(MainWindowLayout.windowMinWidth) меньше суммы колонок \(required). \
            В таком окне правой части некуда сжиматься, и раскладка ломается.
            """
        )
    }

    func test_defaultWidth_fitsFullyExpandedSidebarBesideDetailMinimum() {
        let required = MainWindowLayout.sidebarMaxWidth + MainWindowLayout.detailMinWidth

        XCTAssertGreaterThanOrEqual(
            MainWindowLayout.defaultWindowWidth,
            required,
            """
            Ширина по умолчанию \(MainWindowLayout.defaultWindowWidth) не вмещает \
            раскрытую панель рядом с правой частью (\(required)).
            """
        )
    }

    func test_sidebarWidths_areOrderedMinIdealMax() {
        XCTAssertLessThanOrEqual(MainWindowLayout.sidebarMinWidth, MainWindowLayout.sidebarIdealWidth)
        XCTAssertLessThanOrEqual(MainWindowLayout.sidebarIdealWidth, MainWindowLayout.sidebarMaxWidth)
    }

    /// Минимум окна обязан оставаться выведенным, а не вписанным: вписанное
    /// руками число и есть тот дефект, который этот инвариант закрывает.
    func test_windowMinimumWidth_isDerivedFromColumns_notAStandaloneNumber() {
        XCTAssertEqual(
            MainWindowLayout.windowMinWidth,
            MainWindowLayout.sidebarMinWidth + MainWindowLayout.detailMinWidth
        )
    }
}
