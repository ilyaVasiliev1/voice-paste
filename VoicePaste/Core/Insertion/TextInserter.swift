import AppKit
import ApplicationServices
import CoreGraphics

/// The frontmost application captured before recording begins.  The process
/// id is the delivery boundary: a result is never pasted after focus moved.
public struct FrontAppSnapshot: Sendable, Equatable {
    public let bundleIdentifier: String?
    public let processIdentifier: pid_t

    public init(bundleIdentifier: String?, processIdentifier: pid_t) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
    }
}

/// The HUD reports a delivery attempt only when the OS accepted one normal
/// paste shortcut. Otherwise the completed transcript remains available on
/// the clipboard.
public enum InsertionOutcome: Equatable, Sendable {
    case inserted
    case copied
}

/// A deliberately small, explicit safety decision. We do not inspect an
/// application's AX tree to decide whether an editor deserves paste: modern
/// Electron, Office and web composers all expose that tree inconsistently.
enum PasteTargetEligibility: Equatable, Sendable {
    case capturedApplication
    case clipboardOnly
}

/// The four real key events that form a paste shortcut. Keeping the sequence
/// as data makes the Office-specific regression testable without synthesising
/// live keyboard input from XCTest.
enum HIDPasteStep: Equatable, Sendable {
    case commandDown
    case vDown
    case vUp
    case commandUp

    var virtualKey: CGKeyCode {
        switch self {
        case .commandDown, .commandUp: return 55 // left Command
        case .vDown, .vUp: return 9 // V
        }
    }

    var isKeyDown: Bool {
        switch self {
        case .commandDown, .vDown: return true
        case .vUp, .commandUp: return false
        }
    }

    var flags: CGEventFlags {
        self == .commandUp ? [] : .maskCommand
    }
}

/// One universal desktop delivery path:
///
/// 1. retain the transcript on the system clipboard;
/// 2. post exactly one HID-equivalent Command-V to the application that was
///    active when dictation began and is *still* frontmost.
///
/// It does not use AX text mutation, AppleScript, System Events, Automation,
/// per-app profiles, delayed clipboard restoration or a second retry. Those
/// mechanisms made the old implementation behave differently in ChatGPT,
/// Office, Telegram and Terminal. A normal HID paste is what a user presses
/// themselves, reaches native/Electron/web editors equally, and needs only
/// the Universal Access grant VoicePaste already requests for its global key.
@MainActor
public struct TextInserter {
    public init() {}

    public static func captureFrontAppSnapshot() -> FrontAppSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontAppSnapshot(
            bundleIdentifier: app.bundleIdentifier,
            processIdentifier: app.processIdentifier
        )
    }

    @discardableResult
    public func insert(_ text: String, into snapshot: FrontAppSnapshot?) -> InsertionOutcome {
        // Keeping the completed result on the clipboard is intentional, not
        // a fallback-only side effect. It prevents delayed Electron/Office
        // consumers from losing the payload and always leaves a manual ⌘V.
        Self.copyToClipboard(text)

        guard AccessibilityTrust.isGranted,
              let snapshot,
              isStillFrontmost(snapshot),
              Self.pasteTargetEligibility(bundleIdentifier: snapshot.bundleIdentifier) == .capturedApplication,
              Self.postSingleHIDPaste() else {
            Task { await DiagnosticLog.shared.log("insertion.paste", detail: "outcome=copied") }
            return .copied
        }

        Task {
            await DiagnosticLog.shared.log(
                "insertion.paste",
                detail: "outcome=inserted route=hid"
            )
        }
        return .inserted
    }

    /// Capturing a real external application at record start plus the final
    /// frontmost-PID check protects the destination. The short deny-list
    /// avoids treating file management/system configuration/VoicePaste as a
    /// text destination; every other external app gets the same user-level
    /// paste gesture, regardless of whether it exposes a useful AX tree.
    static func pasteTargetEligibility(bundleIdentifier: String?) -> PasteTargetEligibility {
        guard let bundleIdentifier,
              !nonTextDestinationBundleIdentifiers.contains(bundleIdentifier) else {
            return .clipboardOnly
        }
        return .capturedApplication
    }

    private static let nonTextDestinationBundleIdentifiers: Set<String> = [
        "com.apple.finder",
        "com.apple.systempreferences",
        "com.apple.systemsettings",
        "com.ilyavasiliev.voicepaste",
    ]

    static let standardHIDPasteSequence: [HIDPasteStep] = [
        .commandDown, .vDown, .vUp, .commandUp,
    ]

    /// Posts one standard Command-V through the normal HID route. There is no
    /// per-process event, because Electron and Office do not reliably consume
    /// it; macOS delivers the HID shortcut to the still-frontmost app.
    ///
    /// Modifier keys are emitted as real down/up events instead of attaching
    /// `.maskCommand` only to the V event. Core Graphics documents that a
    /// synthetic shortcut must include *all* of its keystrokes. Office is
    /// noticeably stricter than AppKit and terminal editors here: a flag-only
    /// shortcut can be interpreted as a modified character rather than Paste
    /// (including an upper-case `V`).
    private static func postSingleHIDPaste() -> Bool {
        let permitted = CGPreflightPostEventAccess() || CGRequestPostEventAccess()
        guard permitted, let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }

        for step in standardHIDPasteSequence {
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: step.virtualKey,
                keyDown: step.isKeyDown
            ) else {
                return false
            }
            event.flags = step.flags
            event.post(tap: .cghidEventTap)
        }
        return true
    }

    public static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func isStillFrontmost(_ snapshot: FrontAppSnapshot) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.processIdentifier
    }
}
