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

/// Плашка: контейнер меняет размер плавной пружиной без отскока, старое содержимое
/// уходит раньше, чем контейнер заметно сжался, новое появляется после него.
/// При «Уменьшить движение» размер встаёт на место сразу, содержимое растворяется.
@MainActor
final class HUDMotionTests: XCTestCase {
    func test_surface_isTheSmoothSpring_andAFadeUnderReduceMotion() {
        XCTAssertEqual(HUDMotion.surface(reduceMotion: false), DesignTokens.Motion.surface)
        XCTAssertEqual(HUDMotion.surface(reduceMotion: true), DesignTokens.Motion.fade)
    }

    func test_capsuleSize_doesNotMoveUnderReduceMotion() {
        XCTAssertNil(HUDMotion.size(reduceMotion: true), "размер капсулы двигался при Reduce Motion")
        XCTAssertEqual(HUDMotion.size(reduceMotion: false), DesignTokens.Motion.surface)
    }

    func test_oldContentLeavesBeforeTheCapsuleHasShrunkMuch() {
        let motion = DesignTokens.Motion.self
        XCTAssertLessThan(motion.contentOutDuration, motion.surfaceDuration / 2, "крестик пережил сжатие капсулы")
    }

    func test_surfaceIsQuick() {
        XCTAssertLessThanOrEqual(DesignTokens.Motion.surfaceDuration, 0.3)
    }

    func test_inspectionSlowdown_isOffByDefault() {
        XCTAssertEqual(DesignTokens.Motion.timeScale, 1)
    }
}

/// Смена содержимого плашки идёт по порядку: старое остаётся нарисованным и
/// уходит, затем появляется новое. Иначе крестик остаётся в сжавшейся панели,
/// а новый текст лежит на старом.
@MainActor
final class HUDContentSwapTests: XCTestCase {
    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func test_kindChange_keepsTheOldContentDrawn_andHidesIt() async {
        let holder = HUDStateHolder(swapOutDelay: .milliseconds(40))
        holder.state = .recording(elapsed: 1, level: 0.2)

        holder.state = .processing

        XCTAssertEqual(holder.departing, .recording(elapsed: 1, level: 0.2), "старое содержимое пропало в тот же кадр")
        XCTAssertEqual(holder.contentOpacity, 0)
        let finished = await eventually { holder.departing == nil && holder.contentOpacity == 1 }
        XCTAssertTrue(finished, "новое содержимое так и не появилось")
    }

    func test_tickInsideOneKind_doesNotSwap() {
        let holder = HUDStateHolder(swapOutDelay: .milliseconds(40))
        holder.state = .recording(elapsed: 1, level: 0.2)

        holder.state = .recording(elapsed: 2, level: 0.9)

        XCTAssertNil(holder.departing)
        XCTAssertEqual(holder.contentOpacity, 1)
    }

    func test_appearanceAndDisappearance_areNotSwaps() {
        let holder = HUDStateHolder(swapOutDelay: .milliseconds(40))

        holder.state = .processing
        XCTAssertNil(holder.departing, "появление из пустоты — не смена содержимого")

        holder.state = .hidden
        XCTAssertNil(holder.departing)
        XCTAssertEqual(holder.contentOpacity, 1)
    }

    func test_swapInterruptedByAnotherSwap_endsOnTheLatestState() async {
        let holder = HUDStateHolder(swapOutDelay: .milliseconds(40))
        holder.state = .recording(elapsed: 1, level: 0)
        holder.state = .processing
        holder.state = .copied

        let settled = await eventually { holder.departing == nil && holder.contentOpacity == 1 }

        XCTAssertTrue(settled)
        XCTAssertEqual(holder.state, .copied)
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
