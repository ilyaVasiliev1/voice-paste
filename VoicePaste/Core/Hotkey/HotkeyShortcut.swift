import Foundation
import Carbon.HIToolbox

/// Serializable global-shortcut description (`DM-001.hotkey`).
/// Stores a virtual key code plus a Carbon-compatible modifier mask so the
/// same value can be used both for display (`NSEvent`-style flags) and for
/// registering the low-level event tap in `HotkeyManager`.
public struct HotkeyShortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    /// Raw value of `NSEvent.ModifierFlags` (device-independent subset: command/option/control/shift).
    public var modifierFlags: UInt

    public init(keyCode: UInt32, modifierFlags: UInt) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
    }

    /// Default per `DM-001`: ⌥Space.
    public static let `default` = HotkeyShortcut(
        keyCode: UInt32(kVK_Space),
        modifierFlags: NSEventModifierFlagsOption
    )

    /// Human-readable representation used by the HUD hint and Settings recorder,
    /// e.g. "⌥Space". Kept ASCII/system-symbol only, no hardcoded language strings.
    public var displayString: String {
        var parts = ""
        if modifierFlags & NSEventModifierFlagsControl != 0 { parts += "⌃" }
        if modifierFlags & NSEventModifierFlagsOption != 0 { parts += "⌥" }
        if modifierFlags & NSEventModifierFlagsShift != 0 { parts += "⇧" }
        if modifierFlags & NSEventModifierFlagsCommand != 0 { parts += "⌘" }
        parts += HotkeyShortcut.keyName(for: keyCode)
        return parts
    }

    private static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Escape: return "Esc"
        default: return "Key\(keyCode)"
        }
    }
}

// NSEvent.ModifierFlags raw values, duplicated here to avoid importing AppKit
// into a value type meant to stay lightweight and testable. `nonisolated`:
// under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` a plain top-level `let`
// otherwise defaults to `@MainActor` isolation, but these are read from
// `HotkeyManager.shortcutMatches(...)`, a `nonisolated` function called
// synchronously off the main actor from the CGEventTap's C callback.
nonisolated let NSEventModifierFlagsCommand: UInt = 1 << 20
nonisolated let NSEventModifierFlagsShift: UInt = 1 << 17
nonisolated let NSEventModifierFlagsOption: UInt = 1 << 19
nonisolated let NSEventModifierFlagsControl: UInt = 1 << 18
