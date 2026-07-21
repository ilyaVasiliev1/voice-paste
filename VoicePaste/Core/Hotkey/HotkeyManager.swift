import AppKit
import CoreGraphics
import ApplicationServices

/// Global hotkey listener backed by a listen-only `CGEventTap` (`DEP-005`).
/// Requires Accessibility trust to receive events at all; when trust is not
/// granted, `start()` is a no-op and `isActive` stays `false` — the menu bar
/// "Начать диктовку" action remains the always-available fallback.
@MainActor
public final class HotkeyManager {
    public enum Phase: Sendable {
        case down
        case up
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var shortcut: HotkeyShortcut
    private let onEvent: (Phase) -> Void
    private let onEscape: () -> Void
    // Thread-safe mirror of `shortcut`, read synchronously from the
    // CGEventTap's C callback (bug fix: Option+Space's space character was
    // leaking into the focused app because the callback never consumed the
    // matching key event).
    private let shortcutBox: ShortcutBox
    private let escapeCancellationBox = EscapeCancellationBox()
    // `INV-015`/`AT-090`: mirrors `AppState.readiness.state == .ready`,
    // read synchronously from the CGEventTap's C callback the same way
    // `shortcutBox` is. While `false`, the tap must let a matching hotkey
    // pass through to whatever app is actually frontmost instead of
    // swallowing it for no benefit — the app isn't ready to record.
    private let systemSwallowBox = SystemSwallowBox()

    public init(
        shortcut: HotkeyShortcut,
        onEvent: @escaping (Phase) -> Void,
        onEscape: @escaping () -> Void = {}
    ) {
        self.shortcut = shortcut
        self.shortcutBox = ShortcutBox(shortcut)
        self.onEvent = onEvent
        self.onEscape = onEscape
    }

    public var isActive: Bool { eventTap != nil }

    /// (Re)starts the tap. Safe to call repeatedly; no-op if already active
    /// or if Accessibility trust has not been granted yet.
    public func start() {
        guard eventTap == nil else { return }
        guard AXIsProcessTrusted() else {
            Task { await DiagnosticLog.shared.log("hotkey.start.skipped", detail: "accessibilityNotTrusted") }
            return
        }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // `.defaultTap` (not `.listenOnly`): a listen-only tap can never
        // consume an event regardless of what its callback returns — the
        // system ignores the return value entirely in that mode. Actually
        // swallowing the matched hotkey (the Option+Space bug fix) requires
        // `.defaultTap`, whose callback's returned event is authoritative:
        // returning `nil` drops the event, returning it passes it through.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleTapEvent(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            Task { await DiagnosticLog.shared.log("hotkey.start.failed", detail: "tapCreateFailed") }
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        Task { await DiagnosticLog.shared.log("hotkey.start.success") }
    }

    public func stop() {
        guard eventTap != nil else { return }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        Task { await DiagnosticLog.shared.log("hotkey.stop") }
    }

    /// `AT-011`: assigning a new combination stops matching the old one immediately.
    public func updateShortcut(_ shortcut: HotkeyShortcut) {
        self.shortcut = shortcut
        shortcutBox.update(shortcut)
    }

    /// Escape keeps its normal meaning in the focused app while idle. It is
    /// captured only during a live dictation session, when it cancels that
    /// session without sending Escape into the text field below it.
    public func setEscapeCancellationEnabled(_ isEnabled: Bool) {
        escapeCancellationBox.setEnabled(isEnabled)
    }

    /// `INV-015`/`AT-090`: called from `AppState.refreshReadiness()` whenever
    /// `readiness.state` is recomputed. Only when this is `true` does a
    /// matched hotkey get swallowed by the tap (`.defaultTap` dropping the
    /// event); while `false` the combination reaches the frontmost app
    /// untouched, same as if VoicePaste weren't running a tap at all — the
    /// tap still stays alive to notify `onEvent` so `AppState` can show its
    /// short "not ready" explanation.
    public func setSystemSwallowEnabled(_ isEnabled: Bool) {
        systemSwallowBox.setEnabled(isEnabled)
    }

    /// Called from the CGEventTap C callback, which may run off the main
    /// actor from Swift's static point of view. Decides synchronously
    /// (via `shortcutBox`, not the main-actor `shortcut`) whether this event
    /// *is* the registered hotkey and, if so, returns `nil` so `.defaultTap`
    /// drops it right here — before it can ever reach the focused app (bug
    /// fix: Option+Space's space character leaking through). Notifying
    /// `onEvent` still hops to the main actor, same as before; that hop only
    /// drives side effects (start/stop capture), never the swallow decision,
    /// which must happen synchronously in this same callback invocation.
    private nonisolated func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passRetained(event)
        }
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let flagsRaw = event.flags.rawValue
        let phase: Phase = (type == .keyDown) ? .down : .up
        let isHotkey = shortcutBox.matches(keyCode: keyCode, flagsRaw: flagsRaw)
        let isEscapeCancellation = type == .keyDown
            && keyCode == 53 // kVK_Escape
            && escapeCancellationBox.isEnabled

        Task { @MainActor [weak self] in
            guard let self else { return }
            if isEscapeCancellation {
                self.onEscape()
            } else {
                self.evaluate(keyCode: keyCode, flagsRaw: flagsRaw, phase: phase)
            }
        }

        // `INV-015`/`AT-090`: escape-cancellation is only ever enabled during
        // a live recording session, which itself only exists while ready —
        // it keeps swallowing unconditionally. The hotkey combination itself
        // is only swallowed while `systemSwallowBox` says the app is
        // `ready`; otherwise it passes through to the frontmost app even
        // though `onEvent` above still fires (to show the "not ready"
        // explanation).
        let shouldSwallow = HotkeyManager.shouldSwallow(
            isHotkey: isHotkey,
            isEscapeCancellation: isEscapeCancellation,
            systemSwallowEnabled: systemSwallowBox.isEnabled
        )
        return shouldSwallow ? nil : Unmanaged.passRetained(event)
    }

    /// Pure, `nonisolated`/`static` swallow decision extracted from
    /// `handleTapEvent` for direct unit-testability (`HotkeyManagerTests`,
    /// `AT-090`) without a real event tap or Accessibility trust — mirrors
    /// `shortcutMatches(...)` below in shape and intent. No behavior change:
    /// same boolean expression that used to live inline in `handleTapEvent`.
    nonisolated static func shouldSwallow(
        isHotkey: Bool,
        isEscapeCancellation: Bool,
        systemSwallowEnabled: Bool
    ) -> Bool {
        isEscapeCancellation || (isHotkey && systemSwallowEnabled)
    }

    private func evaluate(keyCode: UInt32, flagsRaw: UInt64, phase: Phase) {
        guard HotkeyManager.shortcutMatches(shortcut, keyCode: keyCode, flagsRaw: flagsRaw) else { return }
        onEvent(phase)
    }

    /// Pure, `nonisolated`/`static` shortcut comparison shared by the
    /// synchronous swallow-decision (`ShortcutBox`, off the main actor) and
    /// the main-actor `evaluate(...)` that actually fires `onEvent` — kept
    /// as one function so the two can never drift apart, and directly unit
    /// -testable (`HotkeyManagerTests`) without a real event tap or
    /// Accessibility trust.
    nonisolated static func shortcutMatches(_ shortcut: HotkeyShortcut, keyCode: UInt32, flagsRaw: UInt64) -> Bool {
        guard keyCode == shortcut.keyCode else { return false }

        let deviceFlags = CGEventFlags(rawValue: flagsRaw)
        let hasCommand = deviceFlags.contains(.maskCommand)
        let hasOption = deviceFlags.contains(.maskAlternate)
        let hasControl = deviceFlags.contains(.maskControl)
        let hasShift = deviceFlags.contains(.maskShift)

        let wantsCommand = shortcut.modifierFlags & NSEventModifierFlagsCommand != 0
        let wantsOption = shortcut.modifierFlags & NSEventModifierFlagsOption != 0
        let wantsControl = shortcut.modifierFlags & NSEventModifierFlagsControl != 0
        let wantsShift = shortcut.modifierFlags & NSEventModifierFlagsShift != 0

        return hasCommand == wantsCommand
            && hasOption == wantsOption
            && hasControl == wantsControl
            && hasShift == wantsShift
    }
}

/// `INV-015`/`AT-090` counterpart to `EscapeCancellationBox`: whether a
/// matched hotkey should actually be swallowed by the tap right now.
/// Defaults to `false` (passthrough) — `AppState.refreshReadiness()` flips
/// it to `true` only once `readiness.state == .ready`, so an app launched
/// with Accessibility already trusted but permissions/model still pending
/// never silently eats the user's chosen combination for no benefit.
private nonisolated final class SystemSwallowBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func setEnabled(_ isEnabled: Bool) {
        lock.lock()
        value = isEnabled
        lock.unlock()
    }
}

private nonisolated final class EscapeCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func setEnabled(_ isEnabled: Bool) {
        lock.lock()
        value = isEnabled
        lock.unlock()
    }
}

/// Thread-safe holder for the shortcut the CGEventTap's C callback compares
/// against. Declared `nonisolated`/`@unchecked Sendable` and lock-protected
/// (like `AudioSampleAccumulator` elsewhere in the app) because the callback
/// runs synchronously off the main actor from Swift's static point of view
/// and must decide, in that same call, whether to swallow the event —
/// there's no time for an actor-isolated `await` hop before returning.
/// `nonisolated`: under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` every
/// declaration in this module defaults to `@MainActor` isolation unless
/// stated otherwise (see the identical note on `AudioSampleAccumulator` in
/// `AudioCaptureService.swift`) — without this, `matches(keyCode:flagsRaw:)`
/// would be `@MainActor`-isolated despite being `Sendable`, and calling it
/// synchronously from the CGEventTap's C callback (which is not on the main
/// actor) would not compile.
private nonisolated final class ShortcutBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: HotkeyShortcut

    init(_ value: HotkeyShortcut) {
        self.value = value
    }

    func update(_ newValue: HotkeyShortcut) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func matches(keyCode: UInt32, flagsRaw: UInt64) -> Bool {
        lock.lock()
        let shortcut = value
        lock.unlock()
        return HotkeyManager.shortcutMatches(shortcut, keyCode: keyCode, flagsRaw: flagsRaw)
    }
}
