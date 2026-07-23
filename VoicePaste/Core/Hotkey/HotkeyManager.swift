import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Global shortcut owner backed by Carbon's registered-hotkey API.
///
/// Unlike a session-wide `CGEventTap`, `RegisterEventHotKey` is not inserted
/// into the delivery path of every keyboard event. macOS sends this object
/// only the two explicitly registered combinations, so a paused process,
/// debugger or busy UI can never stall ordinary typing across the system.
@MainActor
public final class HotkeyManager {
    public enum Phase: Sendable {
        case down
        case up
    }

    private nonisolated static let signature: OSType = 0x5650_5354 // "VPST"
    private nonisolated static let primaryID: UInt32 = 1
    private nonisolated static let escapeID: UInt32 = 2

    private var shortcut: HotkeyShortcut
    private let onEvent: (Phase) -> Void
    private let onEscape: () -> Void
    private var handlerRef: EventHandlerRef?
    private var primaryRef: EventHotKeyRef?
    private var escapeRef: EventHotKeyRef?
    private var shouldRegisterPrimary = false
    private var shouldRegisterEscape = false

    public init(
        shortcut: HotkeyShortcut,
        onEvent: @escaping (Phase) -> Void,
        onEscape: @escaping () -> Void = {}
    ) {
        self.shortcut = shortcut
        self.onEvent = onEvent
        self.onEscape = onEscape
    }

    public var isActive: Bool { primaryRef != nil }

    /// Registers only the configured shortcut. Safe and idempotent; it does
    /// not require Accessibility and cannot observe unrelated keystrokes.
    public func start() {
        shouldRegisterPrimary = true
        guard primaryRef == nil else { return }
        guard installHandlerIfNeeded() else { return }

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.primaryID)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            Self.carbonModifiers(for: shortcut.modifierFlags),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            Task {
                await DiagnosticLog.shared.log(
                    "hotkey.register.failed",
                    detail: "status=\(status)"
                )
            }
            return
        }
        primaryRef = ref
        Task { await DiagnosticLog.shared.log("hotkey.register.success") }
    }

    /// Removes registrations synchronously through Carbon. There is no
    /// worker thread, run-loop join or event-tap callback to wait for.
    public func stop() {
        shouldRegisterPrimary = false
        shouldRegisterEscape = false
        unregister(&escapeRef)
        unregister(&primaryRef)
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        Task { await DiagnosticLog.shared.log("hotkey.stop") }
    }

    public func updateShortcut(_ shortcut: HotkeyShortcut) {
        self.shortcut = shortcut
        guard shouldRegisterPrimary else { return }
        unregister(&primaryRef)
        start()
    }

    /// Escape is registered only for the lifetime of an active recording.
    /// Carbon consumes that one registered key without observing or delaying
    /// any other keyboard input.
    public func setEscapeCancellationEnabled(_ isEnabled: Bool) {
        shouldRegisterEscape = isEnabled
        if isEnabled {
            registerEscapeIfNeeded()
        } else {
            unregister(&escapeRef)
        }
    }

    /// Compatibility name for the readiness gate. A not-ready application
    /// has no registered shortcut at all, so the combination naturally
    /// reaches the foreground app and no callback has to decide whether to
    /// swallow it.
    public func setSystemSwallowEnabled(_ isEnabled: Bool) {
        if isEnabled {
            start()
        } else {
            shouldRegisterPrimary = false
            shouldRegisterEscape = false
            unregister(&escapeRef)
            unregister(&primaryRef)
        }
    }

    private func registerEscapeIfNeeded() {
        guard escapeRef == nil, installHandlerIfNeeded() else { return }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.escapeID)
        let status = RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr { escapeRef = ref }
    }

    private func installHandlerIfNeeded() -> Bool {
        if handlerRef != nil { return true }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        var ref: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandler,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &ref
        )
        guard status == noErr, let ref else { return false }
        handlerRef = ref
        return true
    }

    private func unregister(_ ref: inout EventHotKeyRef?) {
        guard let current = ref else { return }
        UnregisterEventHotKey(current)
        ref = nil
    }

    private func dispatch(id: UInt32, phase: Phase) {
        switch id {
        case Self.primaryID:
            onEvent(phase)
        case Self.escapeID where phase == .down && shouldRegisterEscape:
            onEscape()
        default:
            break
        }
    }

    private nonisolated static let eventHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr, hotKeyID.signature == signature else {
            return OSStatus(eventNotHandledErr)
        }
        let kind = GetEventKind(event)
        let phase: Phase = kind == UInt32(kEventHotKeyReleased) ? .up : .down
        let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
        Task { @MainActor in manager.dispatch(id: hotKeyID.id, phase: phase) }
        return noErr
    }

    nonisolated static func carbonModifiers(for flags: UInt) -> UInt32 {
        var result: UInt32 = 0
        if flags & NSEventModifierFlagsCommand != 0 { result |= UInt32(cmdKey) }
        if flags & NSEventModifierFlagsOption != 0 { result |= UInt32(optionKey) }
        if flags & NSEventModifierFlagsControl != 0 { result |= UInt32(controlKey) }
        if flags & NSEventModifierFlagsShift != 0 { result |= UInt32(shiftKey) }
        return result
    }

    /// Kept as a pure display/recorder helper; runtime delivery is performed
    /// by macOS after registration, not by comparing every key event.
    nonisolated static func shortcutMatches(
        _ shortcut: HotkeyShortcut,
        keyCode: UInt32,
        flagsRaw: UInt64
    ) -> Bool {
        guard keyCode == shortcut.keyCode else { return false }
        let flags = CGEventFlags(rawValue: flagsRaw)
        let actual: UInt = (flags.contains(.maskCommand) ? NSEventModifierFlagsCommand : 0)
            | (flags.contains(.maskAlternate) ? NSEventModifierFlagsOption : 0)
            | (flags.contains(.maskControl) ? NSEventModifierFlagsControl : 0)
            | (flags.contains(.maskShift) ? NSEventModifierFlagsShift : 0)
        return actual == shortcut.modifierFlags
    }
}
