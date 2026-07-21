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
}
