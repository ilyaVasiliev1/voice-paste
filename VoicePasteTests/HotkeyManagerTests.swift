import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import VoicePaste

/// Pure tests for shortcut conversion only. System registration is never
/// started from XCTest; installed-app hotkey behavior belongs to a live smoke.
@MainActor
final class HotkeyManagerTests: XCTestCase {
    func test_shortcutMatches_exactCombination_isTrue() {
        let shortcut = HotkeyShortcut.default
        XCTAssertTrue(HotkeyManager.shortcutMatches(
            shortcut,
            keyCode: shortcut.keyCode,
            flagsRaw: CGEventFlags.maskAlternate.rawValue
        ))
    }

    func test_shortcutMatches_extraModifier_isFalse() {
        let shortcut = HotkeyShortcut.default
        XCTAssertFalse(HotkeyManager.shortcutMatches(
            shortcut,
            keyCode: shortcut.keyCode,
            flagsRaw: CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue
        ))
    }

    func test_shortcutMatches_otherKey_isFalse() {
        let shortcut = HotkeyShortcut.default
        XCTAssertFalse(HotkeyManager.shortcutMatches(
            shortcut,
            keyCode: shortcut.keyCode + 1,
            flagsRaw: CGEventFlags.maskAlternate.rawValue
        ))
    }

    func test_carbonModifiers_mapsEverySupportedModifier() {
        XCTAssertEqual(
            HotkeyManager.carbonModifiers(
                for: NSEventModifierFlagsCommand
                    | NSEventModifierFlagsOption
                    | NSEventModifierFlagsControl
                    | NSEventModifierFlagsShift
            ),
            UInt32(cmdKey | optionKey | controlKey | shiftKey)
        )
    }

    /// This deliberately does not call `start()`: unit tests must never
    /// register a system-wide shortcut or modify the user's input path.
    func test_lifecycleMethodsWithoutStart_haveNoSystemSideEffects() {
        let manager = HotkeyManager(shortcut: .default, onEvent: { _ in })
        manager.updateShortcut(.default)
        manager.setEscapeCancellationEnabled(false)
        manager.setSystemSwallowEnabled(false)
        manager.stop()
        XCTAssertFalse(manager.isActive)
    }
}
