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

    func open(_ id: String) {
        openWindowAction?(id)
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

    private func openAppropriateWindow() {
        guard let appState, let windowRouter else { return }
        appState.refreshReadiness()
        if appState.readiness.state != .ready {
            windowRouter.open("onboarding")
        } else {
            // `UI-004`: the single main window is the "otherwise" reopen
            // target.
            windowRouter.open("main")
        }
    }
}
