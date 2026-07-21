import AppKit
import ApplicationServices
import CoreGraphics

/// Snapshot of the frontmost app taken before recording starts (`L-007`).
public struct FrontAppSnapshot: Sendable, Equatable {
    public let bundleIdentifier: String?
    public let processIdentifier: pid_t

    public init(bundleIdentifier: String?, processIdentifier: pid_t) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
    }
}

/// `API-local-insertText` result (`INV-008`): the HUD must show exactly what
/// happened — a real insertion or an honest clipboard fallback, never one
/// masquerading as the other.
public enum InsertionOutcome: Equatable, Sendable {
    case inserted
    case copied
}

/// The policy decision made before VoicePaste sends a synthetic paste
/// shortcut. This is intentionally a small pure value so its safety rules
/// can be regression-tested without Accessibility permission or a live app.
enum PasteTargetEligibility: Equatable, Sendable {
    /// The current AX tree exposed a concrete editable text surface.
    case verifiedAXTarget
    /// A known editor exposes only an opaque, but non-dangerous, focused
    /// container. This is the deliberately narrow ChatGPT/Electron bridge.
    case opaqueCompatibilityTarget
    /// Clipboard-only: no shortcut may be sent.
    case clipboardOnly
}

/// Attempts a focus-preserving Accessibility insertion into the app that was
/// active before recording started; falls back to the clipboard whenever
/// Accessibility isn't trusted, the target vanished, or the AX call itself
/// fails (`EC-002`, `EC-006`, `AT-003`, `AT-008`).
@MainActor
public struct TextInserter {
    public init() {}

    public static func captureFrontAppSnapshot() -> FrontAppSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontAppSnapshot(bundleIdentifier: app.bundleIdentifier, processIdentifier: app.processIdentifier)
    }

    /// `L-007`: Accessibility is used only to verify that a real editable
    /// target still has focus. Delivery itself has exactly one path:
    /// clipboard + one simulated ⌘V. A second AX `SetSelectedText` path is
    /// deliberately avoided: native editors can accept both operations and
    /// would receive the transcription twice. If paste is not possible, the
    /// text stays on the clipboard as an honest `.copied` (`INV-008`).
    @discardableResult
    public func insert(_ text: String, into snapshot: FrontAppSnapshot?) -> InsertionOutcome {
        guard AXIsProcessTrusted(), let snapshot, isStillFrontmost(snapshot) else {
            Self.copyToClipboard(text)
            return .copied
        }

        let eligibility = pasteTargetEligibility(in: snapshot)
        guard eligibility != .clipboardOnly else {
            Self.copyToClipboard(text)
            return .copied
        }

        if isStillFrontmost(snapshot), pasteViaClipboardAndKeystroke(
            text,
            targetProcessIdentifier: snapshot.processIdentifier,
            eventRoute: Self.pasteEventRoute(for: snapshot),
            restoreDelayNanoseconds: Self.pasteboardRestoreDelay(for: snapshot)
        ) {
            Task {
                await DiagnosticLog.shared.log(
                    "insertion.paste",
                    detail: "outcome=inserted eligibility=\(eligibility) route=\(Self.pasteEventRoute(for: snapshot))"
                )
            }
            return .inserted
        }

        Self.copyToClipboard(text)
        return .copied
    }

    /// A system UI-scripted paste is asynchronous in some Electron and Office
    /// apps. Keep the temporary clipboard for one second; HUD feedback and
    /// typing are never delayed by this value.
    private static func pasteboardRestoreDelay(for snapshot: FrontAppSnapshot) -> UInt64 {
        1_000_000_000
    }

    static func usesExtendedPasteboardWindow(_ snapshot: FrontAppSnapshot) -> Bool {
        let officeBundleIdentifiers: Set<String> = [
            "com.microsoft.Word",
            "com.microsoft.Powerpoint",
            "com.microsoft.Excel",
            "com.microsoft.Outlook",
            "com.microsoft.onenote.mac",
            // Electron composers can read the clipboard asynchronously after
            // the shortcut is delivered. Do not restore it beneath them.
            "com.openai.codex",
            "com.openai.chat",
            "com.anthropic.claudefordesktop",
            "com.microsoft.VSCode",
        ]
        return officeBundleIdentifiers.contains(snapshot.bundleIdentifier ?? "")
    }

    /// System Events emits the ordinary, user-equivalent paste gesture into
    /// the app that was active before dictation. Quartz remains only as a
    /// fallback if the system UI scripting call itself is unavailable.
    enum PasteEventRoute: String, Equatable {
        case process
        case hid
        case systemEvents
    }

    static func pasteEventRoute(for snapshot: FrontAppSnapshot) -> PasteEventRoute {
        .systemEvents
    }

    /// The two-level L-007 admission gate. A concrete editable AX target is
    /// sufficient for every app. The opaque fallback exists only for a small,
    /// named compatibility set; it must never turn Finder, System Settings or
    /// an unknown foreground app into a blind paste target.
    private func pasteTargetEligibility(in snapshot: FrontAppSnapshot) -> PasteTargetEligibility {
        if focusedEditableElement(in: snapshot) != nil {
            return .verifiedAXTarget
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        let hasOpaqueFocusedComposer: Bool
        if let focused = Self.focusedElement(of: systemWideElement),
           Self.element(focused, belongsTo: snapshot),
           let role = Self.role(of: focused) {
            hasOpaqueFocusedComposer = !Self.unsafeOpaqueComposerRoles.contains(role)
        } else {
            hasOpaqueFocusedComposer = false
        }
        return Self.pasteTargetEligibility(
            bundleIdentifier: snapshot.bundleIdentifier,
            hasVerifiedEditableAXTarget: false,
            hasOpaqueFocusedComposer: hasOpaqueFocusedComposer
        )
    }

    static func pasteTargetEligibility(
        bundleIdentifier: String?,
        hasVerifiedEditableAXTarget: Bool,
        hasOpaqueFocusedComposer: Bool
    ) -> PasteTargetEligibility {
        if hasVerifiedEditableAXTarget { return .verifiedAXTarget }
        guard hasOpaqueFocusedComposer,
              knownOpaqueCompatibilityBundleIdentifiers.contains(bundleIdentifier ?? "") else {
            return .clipboardOnly
        }
        return .opaqueCompatibilityTarget
    }

    private static let knownOpaqueCompatibilityBundleIdentifiers: Set<String> = [
        // Desktop AI composers currently expose generic/partial AX nodes.
        "com.openai.codex", "com.openai.chat", "com.anthropic.claudefordesktop",
        // Electron code/chat editors verified in the VoicePaste matrix.
        "com.microsoft.VSCode", "ru.keepcoder.Telegram", "com.tencent.xinWeChat",
    ]

    private static let unsafeOpaqueComposerRoles: Set<String> = [
        "AXWindow", "AXButton", "AXMenuBar", "AXMenuItem", "AXToolbar",
    ]

    /// A focused AX element is a safe paste target only when it identifies as
    /// a known editable text surface. Some web apps expose their composer as
    /// a focused `AXGroup`, with an actual text node one level below it; that
    /// nested node is accepted too. Generic windows/groups/buttons remain
    /// rejected unless they themselves publish writable selected text.
    private func focusedEditableElement(in snapshot: FrontAppSnapshot) -> AXUIElement? {
        // Web runtimes often expose the actual composer via the system-wide
        // focus query, but stop at an implementation-specific container when
        // asked through their application root.
        let systemWideElement = AXUIElementCreateSystemWide()
        if let systemFocused = Self.focusedElement(of: systemWideElement),
           Self.element(systemFocused, belongsTo: snapshot),
           let target = Self.findSafePasteTarget(startingAt: systemFocused) {
            return target
        }

        let appElement = AXUIElementCreateApplication(snapshot.processIdentifier)
        guard let appFocused = Self.focusedElement(of: appElement) else { return nil }
        return Self.findSafePasteTarget(startingAt: appFocused)
    }

    private static func focusedElement(of container: AXUIElement) -> AXUIElement? {
        var focusedElementRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            container,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        ) == .success,
              let focusedElementRef,
              CFGetTypeID(focusedElementRef) == AXUIElementGetTypeID() else {
            return nil
        }
        // swiftlint:disable:next force_cast — type-checked immediately above.
        return (focusedElementRef as! AXUIElement)
    }

    private static func element(_ element: AXUIElement, belongsTo snapshot: FrontAppSnapshot) -> Bool {
        var processIdentifier: pid_t = 0
        AXUIElementGetPid(element, &processIdentifier)
        return processIdentifier == snapshot.processIdentifier
    }

    private static func findSafePasteTarget(startingAt element: AXUIElement) -> AXUIElement? {
        if isSafePasteTarget(element) { return element }
        return firstSafeEditableDescendant(of: element, remainingDepth: 8)
    }

    private static func isSafePasteTarget(_ element: AXUIElement) -> Bool {
        guard let role = role(of: element) else { return false }

        // Some apps publish `AXEditable`; when it explicitly says `false`,
        // honour that. Unsupported/missing is allowed for Terminal/Electron,
        // which still expose a text-area role and accept ⌘V normally.
        var editableRef: AnyObject?
        if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editableRef) == .success,
           let editable = editableRef as? NSNumber,
           !editable.boolValue {
            return false
        }

        // `AXGroup` is allowed only if the particular group exposes a
        // writable selected-text attribute. This covers contenteditable web
        // composers while still excluding Finder's generic window groups.
        var selectedTextSettable = DarwinBoolean(false)
        let selectedTextResult = AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedTextSettable
        )
        return isPasteEligibleRole(role)
            || (selectedTextResult == .success && selectedTextSettable.boolValue)
    }

    private static func role(of element: AXUIElement) -> String? {
        var roleRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success else {
            return nil
        }
        return roleRef as? String
    }

    private static func firstSafeEditableDescendant(
        of element: AXUIElement,
        remainingDepth: Int
    ) -> AXUIElement? {
        guard remainingDepth > 0 else { return nil }
        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if isSafePasteTarget(child) { return child }
            if let nested = firstSafeEditableDescendant(of: child, remainingDepth: remainingDepth - 1) {
                return nested
            }
        }
        return nil
    }

    static func isPasteEligibleRole(_ role: String) -> Bool {
        ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"].contains(role)
    }

    /// Step 2 (`L-007`, owner decision 2026-07-19): puts `text` on the
    /// clipboard, synthesizes a ⌘V keystroke via `CGEvent` — which macOS
    /// delivers to whatever app is currently frontmost, i.e. the snapshot
    /// target, since nothing in this path ever calls `NSApp.activate` or
    /// otherwise raises VoicePaste itself — and restores the clipboard's
    /// prior contents shortly after, best-effort. Returns `false` only if the
    /// synthetic keystroke itself couldn't even be created (clipboard is
    /// restored immediately in that case, and the caller falls back to a
    /// plain clipboard-only `.copied`).
    private func pasteViaClipboardAndKeystroke(
        _ text: String,
        targetProcessIdentifier: pid_t,
        eventRoute: PasteEventRoute,
        restoreDelayNanoseconds: UInt64 = 300_000_000
    ) -> Bool {
        let previous = Self.snapshotPasteboard()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let voicePasteChangeCount = pasteboard.changeCount

        guard Self.simulatePasteKeystroke(
            to: targetProcessIdentifier,
            route: eventRoute
        ) else {
            Self.restorePasteboard(previous)
            return false
        }

        // Best-effort restore once the target app has almost certainly
        // consumed the ⌘V. `Task` here inherits this `@MainActor` struct's
        // isolation (the enclosing method is `@MainActor`), so it's safe to
        // touch `NSPasteboard.general` again from it without re-hopping.
        Task {
            try? await Task.sleep(nanoseconds: restoreDelayNanoseconds)
            // A user's manual copy wins over restoration of the prior
            // clipboard contents while an Office target is consuming paste.
            guard pasteboard.changeCount == voicePasteChangeCount else { return }
            Self.restorePasteboard(previous)
        }
        return true
    }

    /// `virtualKey: 9` is `kVK_ANSI_V` (Carbon `HIToolbox` constant), spelled
    /// out numerically here to avoid pulling in `Carbon.HIToolbox` just for
    /// one key code.
    private static func simulatePasteKeystroke(
        to processIdentifier: pid_t,
        route: PasteEventRoute
    ) -> Bool {
        if route == .systemEvents {
            // Used only for ChatGPT. It preserves the current target focus
            // and never activates VoicePaste; macOS may ask once for
            // Automation permission to control System Events.
            var error: NSDictionary?
            let script = NSAppleScript(
                source: "tell application \\\"System Events\\\" to keystroke \\\"v\\\" using {command down}"
            )
            _ = script?.executeAndReturnError(&error)
            if error == nil { return true }
            // If Automation was explicitly denied or unavailable, preserve a
            // best-effort Quartz fallback. It is still one paste delivery:
            // System Events reported an error before sending the shortcut.
            return simulateQuartzPasteKeystroke(to: processIdentifier, route: .hid)
        }

        return simulateQuartzPasteKeystroke(to: processIdentifier, route: route)
    }

    private static func simulateQuartzPasteKeystroke(
        to processIdentifier: pid_t,
        route: PasteEventRoute
    ) -> Bool {
        let vKeyCode: CGKeyCode = 9
        // Quartz event posting is the supported macOS route for the normal
        // system paste gesture. It needs the same Accessibility TCC consent
        // requested during onboarding.
        guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else { return false }
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        switch route {
        case .process:
            // Direct process delivery avoids fragile session routing in
            // Office and native applications.
            keyDown.postToPid(processIdentifier)
            keyUp.postToPid(processIdentifier)
        case .hid:
            // Electron desktop composers consume a normal HID shortcut more
            // reliably than a PID-directed Quartz event.
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        case .systemEvents:
            preconditionFailure("System Events route returns before CGEvent creation")
        }
        return true
    }

    /// Captures every type currently on the general pasteboard as raw
    /// `Data`, so `restorePasteboard(_:)` can put back exactly what was
    /// there before the clipboard-and-paste fallback overwrote it — not just
    /// its plain-text form. Internal (not `private`) so
    /// `TextInserterTests` can exercise the round-trip directly without
    /// requiring Accessibility trust.
    static func snapshotPasteboard() -> [NSPasteboard.PasteboardType: Data] {
        let pasteboard = NSPasteboard.general
        guard let types = pasteboard.types else { return [:] }
        var snapshot: [NSPasteboard.PasteboardType: Data] = [:]
        for type in types {
            if let data = pasteboard.data(forType: type) {
                snapshot[type] = data
            }
        }
        return snapshot
    }

    /// Restores a snapshot captured by `snapshotPasteboard()`. An empty
    /// snapshot (clipboard was empty beforehand) restores to an empty
    /// clipboard rather than leaving VoicePaste's own text sitting there.
    static func restorePasteboard(_ snapshot: [NSPasteboard.PasteboardType: Data]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        let item = NSPasteboardItem()
        for (type, data) in snapshot {
            item.setData(data, forType: type)
        }
        pasteboard.writeObjects([item])
    }

    private func isStillFrontmost(_ snapshot: FrontAppSnapshot) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.processIdentifier
    }

    public static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
