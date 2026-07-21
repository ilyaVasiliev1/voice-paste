import AppKit
import SwiftUI

/// `UI-001`. All actions stay visible even when disabled — only their
/// enabled state changes with readiness.
struct MenuBarContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        // UI-001: menu bar stays a calm navigation/control surface. Dictation
        // remains the global hotkey; import lives in main detail or HUD.
        // `INV-015`/`AT-088`: routed through `AppState`'s single
        // ready-vs-onboarding gate, same as "Статистика" below — not a bare
        // `presentWindow(id: "main")` that would ignore readiness.
        Button("menu.openMain") {
            appState.openMainOrOnboarding(section: .history)
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
            // and gains focus even in menu-bar-only (`.accessory`) mode —
            // this does not touch `activationPolicy`, so the Dock icon stays
            // as `applyDockVisibility()` last set it.
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        }

        Divider()

        Button("menu.quit") {
            appState.prepareForQuit()
            NSApp.terminate(nil)
        }

    }

}
