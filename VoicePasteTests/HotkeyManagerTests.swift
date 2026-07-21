import CoreGraphics
import XCTest
@testable import VoicePaste

/// Unit tests for `HotkeyManager.shortcutMatches(_:keyCode:flagsRaw:)` — the
/// pure comparison that both `ShortcutBox` (the CGEventTap's synchronous
/// swallow decision, bug fix for Option+Space leaking a space character) and
/// `evaluate(...)` (the main-actor `onEvent` gate) share.
///
/// `HotkeyManager.start()` itself can't be exercised headlessly: it's a
/// no-op whenever `AXIsProcessTrusted()` is `false`, which is always the case
/// under `xcodebuild test` (no TCC grant for the test runner process) — so
/// the actual event tap / consuming behavior can only be verified by hand in
/// a running app with Accessibility trust granted.
@MainActor
final class HotkeyManagerTests: XCTestCase {

    // MARK: - Default shortcut (⌥Space)

    func test_shortcutMatches_exactCombination_isTrue() {
        let shortcut = HotkeyShortcut.default
        let flags = CGEventFlags.maskAlternate.rawValue

        XCTAssertTrue(HotkeyManager.shortcutMatches(shortcut, keyCode: shortcut.keyCode, flagsRaw: flags))
    }

    /// Unrelated key events (e.g. the user typing normally) must never be
    /// reported as a match — the tap must only ever swallow the registered
    /// combination, nothing else.
    func test_shortcutMatches_differentKeyCode_isFalse() {
        let shortcut = HotkeyShortcut.default
        let flags = CGEventFlags.maskAlternate.rawValue

        XCTAssertFalse(HotkeyManager.shortcutMatches(shortcut, keyCode: shortcut.keyCode + 1, flagsRaw: flags))
    }

    func test_shortcutMatches_noModifierHeld_isFalse() {
        let shortcut = HotkeyShortcut.default

        XCTAssertFalse(HotkeyManager.shortcutMatches(shortcut, keyCode: shortcut.keyCode, flagsRaw: 0))
    }

    /// An extra modifier held at the same time (e.g. ⌘⌥Space) is a different
    /// combination and must not match.
    func test_shortcutMatches_extraModifierHeld_isFalse() {
        let shortcut = HotkeyShortcut.default
        let flags = CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue

        XCTAssertFalse(HotkeyManager.shortcutMatches(shortcut, keyCode: shortcut.keyCode, flagsRaw: flags))
    }

    // MARK: - A different registered shortcut (e.g. ⌘⇧D)

    func test_shortcutMatches_multiModifierShortcut_exactCombination_isTrue() {
        let shortcut = HotkeyShortcut(keyCode: 2, modifierFlags: NSEventModifierFlagsCommand | NSEventModifierFlagsShift)
        let flags = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue

        XCTAssertTrue(HotkeyManager.shortcutMatches(shortcut, keyCode: 2, flagsRaw: flags))
    }

    func test_shortcutMatches_multiModifierShortcut_missingOneModifier_isFalse() {
        let shortcut = HotkeyShortcut(keyCode: 2, modifierFlags: NSEventModifierFlagsCommand | NSEventModifierFlagsShift)
        let flags = CGEventFlags.maskCommand.rawValue

        XCTAssertFalse(HotkeyManager.shortcutMatches(shortcut, keyCode: 2, flagsRaw: flags))
    }

    // MARK: - AT-090: `HotkeyManager.shouldSwallow` (`INV-015`, `SystemSwallowBox`)
    //
    // `shouldSwallow(isHotkey:isEscapeCancellation:systemSwallowEnabled:)` is
    // the pure, `nonisolated static` extraction of the swallow decision that
    // used to live only inline inside the private `handleTapEvent(...)`,
    // reachable only through a real `CGEventTap` callback requiring
    // `AXIsProcessTrusted() == true` (never granted to the `xcodebuild test`
    // runner — see the class doc above). Now that the boolean expression is
    // its own static function, it is directly unit-testable without a real
    // event tap, Accessibility trust, or a system hotkey press — this covers
    // the *decision logic* of AT-090/INV-015 deterministically. It does NOT
    // cover the system-level wiring (whether `CGEventTap`'s `.defaultTap`
    // actually drops the event, whether the frontmost app truly receives the
    // passthrough character) — that remains `живой smoke` on an installed
    // `.app` with real Accessibility trust, before/after `readiness == ready`.
    //
    // All four boolean-input combinations relevant to the decision
    // (`isHotkey` × `systemSwallowEnabled`, with escape-cancellation on/off)
    // are enumerated below; `isEscapeCancellation` short-circuits to `true`
    // unconditionally per the `||`, so it is checked in both states too.

    /// Core AT-090/INV-015 criterion: the registered hotkey must pass through
    /// to the frontmost app while the system-swallow gate is not yet enabled
    /// (i.e. before `readiness == ready`) — this is what "не проглатывается"
    /// in AT-090's expected result means. Regresses if the `&&` in
    /// `shouldSwallow` is ever loosened to swallow unconditionally on
    /// `isHotkey` alone.
    func test_shouldSwallow_hotkeyNotReady_isFalse_passthrough() {
        XCTAssertFalse(
            HotkeyManager.shouldSwallow(isHotkey: true, isEscapeCancellation: false, systemSwallowEnabled: false),
            "AT-090: an unmatched-readiness hotkey must pass through to the active app, not be swallowed"
        )
    }

    /// Counterpart: once ready, the same hotkey combination *is* swallowed —
    /// this is the Option+Space leaking-space-character bug fix this gate
    /// must not regress. Catches the gate being disabled entirely (always
    /// passthrough) or inverted.
    func test_shouldSwallow_hotkeyReady_isTrue() {
        XCTAssertTrue(
            HotkeyManager.shouldSwallow(isHotkey: true, isEscapeCancellation: false, systemSwallowEnabled: true)
        )
    }

    /// Escape-cancellation swallows unconditionally regardless of the
    /// system-swallow gate (it is only ever enabled during a live recording
    /// session, which itself implies readiness) — checked in both gate
    /// states so a future refactor cannot accidentally make it depend on
    /// `systemSwallowEnabled`.
    func test_shouldSwallow_escapeCancellation_isTrue_regardlessOfSystemSwallowEnabled() {
        XCTAssertTrue(
            HotkeyManager.shouldSwallow(isHotkey: false, isEscapeCancellation: true, systemSwallowEnabled: false)
        )
        XCTAssertTrue(
            HotkeyManager.shouldSwallow(isHotkey: false, isEscapeCancellation: true, systemSwallowEnabled: true)
        )
    }

    /// Neither the registered hotkey nor an escape-cancellation: an ordinary
    /// keystroke must never be swallowed, independent of the system-swallow
    /// gate. Regresses if the gate is ever checked without also requiring
    /// `isHotkey`.
    func test_shouldSwallow_neitherHotkeyNorEscape_isFalse_regardlessOfSystemSwallowEnabled() {
        XCTAssertFalse(
            HotkeyManager.shouldSwallow(isHotkey: false, isEscapeCancellation: false, systemSwallowEnabled: false)
        )
        XCTAssertFalse(
            HotkeyManager.shouldSwallow(isHotkey: false, isEscapeCancellation: false, systemSwallowEnabled: true)
        )
    }

    // MARK: - INV-016 regression: no main-actor work for ordinary typing

    /// Regression for a real system-freeze incident: the event tap used to
    /// enqueue a `Task { @MainActor ... }` for every key down and key up.
    /// Typing normally then flooded the app's UI queue and caused timeout
    /// disables. Only the actual hotkey or an enabled Escape cancellation
    /// may cross from the tap thread into app state.
    func test_shouldDispatchToAppState_ordinaryKey_isFalse() {
        XCTAssertFalse(
            HotkeyManager.shouldDispatchToAppState(isHotkey: false, isEscapeCancellation: false)
        )
    }

    func test_shouldDispatchToAppState_hotkeyOrEscape_isTrue() {
        XCTAssertTrue(
            HotkeyManager.shouldDispatchToAppState(isHotkey: true, isEscapeCancellation: false)
        )
        XCTAssertTrue(
            HotkeyManager.shouldDispatchToAppState(isHotkey: false, isEscapeCancellation: true)
        )
    }

    /// `setSystemSwallowEnabled(_:)` remains the only public surface that
    /// drives `systemSwallowEnabled` into the real `CGEventTap` callback path
    /// (`SystemSwallowBox`, not directly testable headlessly per the class
    /// doc above); this guards its lifecycle-safety shape only — not a
    /// behavior proof of the swallow decision itself, which the tests above
    /// now cover directly via `shouldSwallow`.
    func test_setSystemSwallowEnabled_isCallable_beforeAndAfterStart_withoutCrashing() {
        let manager = HotkeyManager(shortcut: .default, onEvent: { _ in }, onEscape: {})

        manager.setSystemSwallowEnabled(false)
        manager.start() // no-op under xcodebuild test: no Accessibility trust
        manager.setSystemSwallowEnabled(true)
        manager.setSystemSwallowEnabled(false)
        manager.stop()

        XCTAssertFalse(manager.isActive, "start() must stay a no-op without Accessibility trust in this environment")
    }
}
