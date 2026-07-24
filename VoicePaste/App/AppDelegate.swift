import AppKit
import SwiftUI

/// `UI-001` (Присутствие приложения): SwiftUI's `openWindow` environment
/// action is only readable from inside a `View`/`Scene` body, but
/// `AppDelegate` (an `NSObject`) needs to trigger the same window-opening
/// logic from `applicationShouldHandleReopen`. `VoicePasteApp` captures its
/// own `openWindow` action into this router once at launch; the delegate
/// then calls through it without ever touching SwiftUI environment itself.
@MainActor
final class WindowRouter {
    static let shared = WindowRouter()
    var openWindowAction: ((String) -> Void)?
    /// `AT-091`: `VoicePasteApp` captures the documented `@Environment(\.openSettings)`
    /// action here, the same way it captures `openWindow` above — `AppState`
    /// (an `NSObject`-free plain class with no SwiftUI environment access)
    /// routes "Настройки…" through this closure instead of sending the
    /// private `showSettingsWindow:` selector.
    var openSettingsAction: (() -> Void)?

    func open(_ id: String) {
        openWindowAction?(id)
    }

    func openSettings() {
        openSettingsAction?()
    }
}

/// `UI-001`: with `LSUIElement` off the app has a Dock icon and participates
/// in the standard Dock-click "reopen" gesture. Clicking the Dock icon while
/// no window is visible must resurface the appropriate window (onboarding if
/// not yet ready, the single main window otherwise, `UI-004`) rather than
/// doing nothing. The app is also a menu-bar/hotkey resident
/// (`US-008`/`INV-011`), so closing every window must not quit it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?
    var windowRouter: WindowRouter?

    /// The unit gate runs VoicePaste as its own XCTest host. A `.regular` host
    /// takes a Dock icon and foregrounds itself the instant it finishes
    /// launching — before any test runs — turning a headless `xcodebuild test`
    /// into a GUI pop that steals focus. Under the test runtime *only*, adopt
    /// the non-activating `.prohibited` policy so the gate runs headless. This
    /// is the same "never do X merely because a unit bundle loaded us" guard the
    /// app already applies to its database, queue and preferences
    /// (`ProcessRuntime.isRunningTests`). Production launch keeps `.regular` and
    /// the readiness-driven Dock visibility (`AppState.applyDockVisibility`)
    /// entirely untouched — this method returns immediately when not testing.
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard ProcessRuntime.isRunningTests else { return }
        NSApp.setActivationPolicy(.prohibited)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        if !flag {
            openAppropriateWindow()
        }
        return true
    }

    /// `INV-015`/`AT-089`: Dock-reopen funnels through the exact same
    /// ready-vs-onboarding router as the menu bar's "Открыть VoicePaste"/
    /// "Статистика" (`AppState.openMainOrOnboarding`) — so a Dock click and a
    /// menu click can never disagree on where a not-yet-ready app sends the
    /// user.
    private func openAppropriateWindow() {
        guard let appState else { return }
        appState.refreshReadiness()
        appState.openMainOrOnboarding(section: .history)
    }
}

/// `VP-BUG-001`: the decision a resident app makes at launch when another copy
/// of itself may already be running, plus the launch hook that acts on it.
///
/// `decide` is a pure function of the running-app set, this app's bundle id and
/// its own pid — no `NSWorkspace`, no `NSApplication`, no termination — so it is
/// provable without launching two real processes. It is `nonisolated`: a pure
/// value computation with no main-actor state, opted out of the module's default
/// main-actor isolation so it (and its `Equatable` results) can be compared from
/// a plain synchronous test.
nonisolated enum SingleInstanceGuard {
    /// The minimum a running application contributes to the decision, so a test
    /// can supply fakes instead of constructing `NSRunningApplication`.
    struct RunningInstance: Equatable {
        let bundleIdentifier: String?
        let processIdentifier: pid_t
    }

    enum Decision: Equatable {
        /// No other instance owns this bundle id: this process is the app.
        case proceed
        /// Another instance is already running; hand off to it — activate it and
        /// exit rather than starting a second copy. Names the instance to defer
        /// to: the oldest surviving one, identified by the lowest pid.
        case deferToExisting(pid: pid_t)
    }

    /// Deterministic and side-effect free.
    static func decide(
        running: [RunningInstance],
        bundleIdentifier: String,
        currentPID: pid_t
    ) -> Decision {
        let others = running
            .filter { $0.bundleIdentifier == bundleIdentifier && $0.processIdentifier != currentPID }
            .map(\.processIdentifier)
        guard let oldest = others.min() else { return .proceed }
        return .deferToExisting(pid: oldest)
    }

    /// Applies the decision to the live system. Maps the real running-app set
    /// into `decide` and, when another instance already owns this bundle id,
    /// activates it and exits — before the caller creates any UI, hotkey or
    /// database. If the chosen instance has already vanished by the time it is
    /// resolved (a snapshot race), this process proceeds and becomes the app
    /// rather than exiting to nothing. A no-op under the XCTest runtime, which
    /// keeps `VPGATE-001`'s headless host and unit tests unaffected.
    @MainActor
    static func enforce() {
        guard !ProcessRuntime.isRunningTests else { return }
        let current = NSRunningApplication.current
        guard let bundleID = Bundle.main.bundleIdentifier ?? current.bundleIdentifier else { return }
        let running = NSWorkspace.shared.runningApplications.map {
            RunningInstance(bundleIdentifier: $0.bundleIdentifier, processIdentifier: $0.processIdentifier)
        }
        guard case let .deferToExisting(pid) = decide(
            running: running,
            bundleIdentifier: bundleID,
            currentPID: current.processIdentifier
        ) else { return }
        guard let existing = NSRunningApplication(processIdentifier: pid) else { return }
        existing.activate()
        exit(0)
    }
}
