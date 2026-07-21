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

    // `INV-016`/`AT-097`: owns the CGEventTap's dedicated background thread
    // and `CFRunLoop`. Never add the tap's source to `CFRunLoopGetMain()` —
    // doing so ties hotkey delivery (and the ability to swallow the matched
    // combination at all) to however busy the main thread happens to be,
    // which can freeze system-wide keyboard input while SwiftUI is doing
    // something else on it.
    private let eventTapRunner = EventTapRunner()
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

    public var isActive: Bool { eventTapRunner.isRunning }

    /// (Re)starts the tap. Safe to call repeatedly; no-op if already active
    /// or if Accessibility trust has not been granted yet. The tap itself is
    /// created, attached to a run loop and enabled entirely on
    /// `eventTapRunner`'s own dedicated background thread (`INV-016`) —
    /// this method only kicks that off and reports the outcome to the log.
    public func start() {
        guard !eventTapRunner.isRunning else { return }
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
        eventTapRunner.start(
            mask: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleTapEvent(type: type, event: event)
            },
            refcon: refcon
        ) { didStart in
            Task {
                if didStart {
                    await DiagnosticLog.shared.log("hotkey.start.success")
                } else {
                    await DiagnosticLog.shared.log("hotkey.start.failed", detail: "tapCreateFailed")
                }
            }
        }
    }

    /// Idempotent: disables the tap, tears down its run loop source and
    /// stops/joins the dedicated background thread before returning
    /// (`INV-016`). A second call while already stopped is a no-op.
    public func stop() {
        guard eventTapRunner.isRunning else { return }
        eventTapRunner.stop()
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
        // `INV-016`/`AT-097`: macOS disables an event tap on its own — no
        // subscription needed to receive these two types — either after it
        // judges the callback too slow (`.tapDisabledByTimeout`) or after a
        // burst of user input (`.tapDisabledByUserInput`). Left alone the
        // hotkey would silently stop working until the app is relaunched;
        // re-enable it immediately, synchronously, right here. `event` is
        // not a real key event for these two types, so it is simply passed
        // through unmodified rather than evaluated for swallowing.
        guard type != .tapDisabledByTimeout, type != .tapDisabledByUserInput else {
            eventTapRunner.reenable()
            let reason = type == .tapDisabledByTimeout ? "timeout" : "userInput"
            Task { await DiagnosticLog.shared.log("hotkey.tap.reenabled", detail: "reason=\(reason)") }
            return Unmanaged.passRetained(event)
        }

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

        // A global event tap receives *every* keystroke. Scheduling a main
        // actor task for ordinary typing created an unbounded queue while the
        // user was writing in another application. That starved VoicePaste's
        // UI and eventually made macOS disable the event tap for a timeout.
        // Only the registered shortcut (or Escape during an active recording)
        // is relevant to this app; all other input must return from this
        // callback without allocating work or touching the main actor.
        if HotkeyManager.shouldDispatchToAppState(
            isHotkey: isHotkey,
            isEscapeCancellation: isEscapeCancellation
        ) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if isEscapeCancellation {
                    self.onEscape()
                } else {
                    self.evaluate(keyCode: keyCode, flagsRaw: flagsRaw, phase: phase)
                }
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

    /// `INV-016` regression: ordinary input must never enqueue a main-actor task
    /// from the global tap. This is deliberately separate from
    /// `shouldSwallow`: an unready hotkey still needs an app-state callback
    /// to show its "not ready" feedback, even though it is passed through to
    /// the frontmost app.
    nonisolated static func shouldDispatchToAppState(
        isHotkey: Bool,
        isEscapeCancellation: Bool
    ) -> Bool {
        isHotkey || isEscapeCancellation
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

/// A plain wrapper making an `UnsafeMutableRawPointer?` explicitly
/// `Sendable` at the one place it needs to cross into a `Thread`'s
/// `@Sendable` body (`EventTapRunner.start`). The pointer is `refcon` —
/// `Unmanaged.passUnretained(self).toOpaque()` for the owning
/// `HotkeyManager` — used only to recover that reference inside the tap's
/// C callback; nothing here ever dereferences or mutates through it
/// directly.
private nonisolated struct RawPointerBox: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer?

    init(_ pointer: UnsafeMutableRawPointer?) {
        self.pointer = pointer
    }
}

/// Owns the `CGEventTap`'s dedicated background thread and its own
/// `CFRunLoop` (`INV-016`/`AT-097`). A `CGEventTap`'s callback only ever
/// fires on whichever run loop its `CFRunLoopSource` was added to; adding it
/// to the main run loop (the anti-pattern this type replaces) means hotkey
/// delivery for the entire system stalls for as long as the main thread is
/// busy doing anything else — a SwiftUI layout pass, a sheet, a long
/// synchronous call. This type instead runs the tap's whole lifecycle
/// (create → add source to the current thread's run loop → enable →
/// `CFRunLoopRun()`) on one dedicated `Thread`, created fresh by `start()`
/// and joined by the matching `stop()`, so the main actor's own busyness can
/// never affect whether the hotkey fires.
///
/// `nonisolated`/`@unchecked Sendable` and lock-protected for the same
/// reason as `ShortcutBox` below: `reenable()` is called synchronously from
/// the tap's C callback, which the C API always runs off the main actor
/// from Swift's static point of view (here, literally on this type's own
/// background thread), and there is no time for an actor hop before the
/// callback must return.
private nonisolated final class EventTapRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var doneSemaphore: DispatchSemaphore?
    private var running = false

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// Starts the dedicated thread if one isn't already running; a second
    /// call while one is already active is a no-op. `onStarted` fires
    /// exactly once, off the main actor, reporting whether
    /// `CGEvent.tapCreate` actually succeeded — the caller hops back to the
    /// main actor itself to log the outcome.
    func start(
        mask: CGEventMask,
        callback: @escaping CGEventTapCallBack,
        refcon: UnsafeMutableRawPointer?,
        onStarted: @escaping @Sendable (Bool) -> Void
    ) {
        lock.lock()
        guard thread == nil else {
            lock.unlock()
            return
        }
        running = true
        let semaphore = DispatchSemaphore(value: 0)
        doneSemaphore = semaphore
        // `UnsafeMutableRawPointer?` itself is not `Sendable`, but it is
        // just a plain pointer value here — the object it addresses
        // (`HotkeyManager`, via `Unmanaged.passUnretained`) is never mutated
        // through this pointer, only unwrapped back into a reference inside
        // the tap's callback. Boxing it makes that safety explicit to the
        // compiler at the one crossing point (`Thread`'s `@Sendable` body).
        let refconBox = RawPointerBox(refcon)
        let newThread = Thread { [weak self] in
            self?.runLoopBody(
                mask: mask,
                callback: callback,
                refcon: refconBox.pointer,
                doneSemaphore: semaphore,
                onStarted: onStarted
            )
        }
        newThread.name = "com.voicepaste.hotkeyEventTap"
        // The tap's callback must never be starved behind other background
        // work; this thread does nothing but block in `CFRunLoopRun()` and
        // run the tiny synchronous callback.
        newThread.qualityOfService = .userInteractive
        thread = newThread
        lock.unlock()

        newThread.start()
    }

    /// The entire body of the dedicated thread. Everything here — tap
    /// creation, attaching the source to a run loop, enabling the tap —
    /// must happen on this same thread: `CFRunLoopGetCurrent()` only
    /// returns *this* thread's run loop when called from it, and a
    /// `CFRunLoopSource` added to one thread's run loop never fires on
    /// another thread's.
    private func runLoopBody(
        mask: CGEventMask,
        callback: @escaping CGEventTapCallBack,
        refcon: UnsafeMutableRawPointer?,
        doneSemaphore: DispatchSemaphore,
        onStarted: @escaping @Sendable (Bool) -> Void
    ) {
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        ), let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            lock.lock()
            running = false
            thread = nil
            lock.unlock()
            doneSemaphore.signal()
            onStarted(false)
            return
        }

        let currentRunLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(currentRunLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        lock.lock()
        self.tap = tap
        self.runLoop = currentRunLoop
        lock.unlock()

        onStarted(true)

        // Blocks this thread — and only this thread — until `stop()` calls
        // `CFRunLoopStop(currentRunLoop)` below.
        CFRunLoopRun()

        CFRunLoopRemoveSource(currentRunLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: false)

        lock.lock()
        self.tap = nil
        self.runLoop = nil
        self.thread = nil
        running = false
        lock.unlock()

        doneSemaphore.signal()
    }

    /// Re-enables the tap in place, synchronously, from whatever thread the
    /// tap's own callback is already executing on (`INV-016`/`AT-097`): the
    /// system disables a tap on its own after it judges the callback too
    /// slow, or after a burst of user input; without this the hotkey would
    /// silently stop working until the app is relaunched.
    func reenable() {
        lock.lock()
        let tap = self.tap
        lock.unlock()
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Idempotent: a `stop()` with no active thread is a no-op. Blocks the
    /// calling thread — the main actor, briefly — until the dedicated
    /// thread has actually finished tearing down (disabled the tap, removed
    /// its source, exited `CFRunLoopRun()`), so a following `start()` can
    /// never race with this `stop()`'s cleanup.
    func stop() {
        lock.lock()
        guard let runLoop, let semaphore = doneSemaphore else {
            lock.unlock()
            return
        }
        lock.unlock()

        CFRunLoopStop(runLoop)
        semaphore.wait()

        lock.lock()
        doneSemaphore = nil
        lock.unlock()
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
