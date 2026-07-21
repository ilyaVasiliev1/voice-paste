import AppKit
import SwiftUI

/// `UI-001`. All actions stay visible even when disabled — only their
/// enabled state changes with readiness.
struct MenuBarContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // UI-001: menu bar stays a calm navigation/control surface. Dictation
        // remains the global hotkey; import lives in main detail or HUD.
        Button("menu.openMain") {
            presentWindow(id: "main")
        }

        Button("menu.statistics") {
            appState.openStatistics()
        }

        Button(appState.settings.showInDock ? "menu.hideFromDock" : "menu.showInDock") {
            appState.settings.showInDock.toggle()
            appState.applyDockVisibility()
        }

        Divider()

        Button("menu.settings") {
            appState.openSettings()
        }

        Button("menu.about") {
            // `AT-087`: activate first so the About panel reaches the front
            // and gains focus even in menu-bar-only (`.accessory`) mode,
            // same as `presentWindow` below — this does not touch
            // `activationPolicy`, so the Dock icon stays hidden.
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        }

        Divider()

        Button("menu.quit") {
            appState.prepareForQuit()
            NSApp.terminate(nil)
        }

    }

    /// `UI-002`: a `Window` scene opened while another app is frontmost can
    /// otherwise appear *behind* it. Activating the app first ensures the
    /// window actually reaches the front, regardless of Dock presence.
    private func presentWindow(id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }

}
