import SwiftUI
import XCTest

@testable import VoicePaste

/// Движение живёт в токенах: вид берёт готовое и не пишет числа сам.
@MainActor
final class MotionTokensTests: XCTestCase {
    func test_reduceMotion_replacesAnyMotionWithAShortFade() {
        let reduced = DesignTokens.Motion.respecting(DesignTokens.Motion.scroll, reduceMotion: true)

        XCTAssertEqual(
            reduced, Animation.easeOut(duration: DesignTokens.Motion.quick),
            "Reduce Motion дал движение или «ничего»"
        )
    }

    func test_withoutReduceMotion_theAnimationIsUntouched() {
        XCTAssertEqual(
            DesignTokens.Motion.respecting(DesignTokens.Motion.scroll, reduceMotion: false),
            DesignTokens.Motion.scroll
        )
    }

    func test_exit_isFasterThanTheSurfaceChange() {
        XCTAssertLessThan(DesignTokens.Motion.exit, DesignTokens.Motion.standard)
    }
}

/// Полоска автозакрытия видна у двух состояний; цикл в 30 Гц нужен только им.
final class HUDDismissProgressTests: XCTestCase {
    func test_onlyUndoAndImportResult_showTheDismissBar() {
        let shown: [HUDState] = [.cancelledWithUndo, .importFinished(text: "t", transcriptID: UUID())]
        let hidden: [HUDState] = [
            .hidden, .recording(elapsed: 1, level: 0), .processing, .inserted, .copied, .cancelled,
            .error(message: "m"), .importIdle, .importing, .importOpened,
        ]

        XCTAssertTrue(shown.allSatisfy(\.showsDismissProgress))
        XCTAssertTrue(hidden.allSatisfy { !$0.showsDismissProgress })
    }
}

/// Выход плашки — растворение 120 мс, а не обрыв; первый показ сессии не
/// платит за создание поверхности.
@MainActor
final class HUDWindowControllerMotionTests: XCTestCase {
    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    func test_hide_fadesOutInsteadOfCuttingOff_thenResetsForTheNextShow() async {
        let hud = HUDWindowController()
        hud.present(.processing)
        XCTAssertTrue(hud.isPanelVisible)

        hud.hide()

        XCTAssertTrue(hud.isPanelVisible, "плашка пропала в тот же кадр — выхода нет")
        let gone = await eventually { !hud.isPanelVisible }
        XCTAssertTrue(gone)
        XCTAssertEqual(hud.panelAlpha, 1, "прозрачная панель испортила бы следующий показ")
    }

    func test_presentDuringExit_cancelsTheExit() async {
        let hud = HUDWindowController()
        hud.present(.processing)
        hud.hide()

        hud.present(.inserted)
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(hud.isPanelVisible, "новый показ задело старым выходом")
        XCTAssertEqual(hud.panelAlpha, 1)
    }

    func test_prewarm_leavesNothingOnScreen_andTheNextShowIsOpaque() {
        let hud = HUDWindowController()

        hud.prewarm()

        XCTAssertFalse(hud.isPanelVisible)
        XCTAssertEqual(hud.panelAlpha, 1)
        hud.present(.recording(elapsed: 0, level: 0))
        XCTAssertTrue(hud.isPanelVisible)
        XCTAssertEqual(hud.panelAlpha, 1)
    }
}
