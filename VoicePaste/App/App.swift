import AppKit
import SwiftUI

@main
struct VoicePasteApp: App {
    @StateObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let windowRouter = WindowRouter.shared

    init() {
        let settings = AppSettings()
        let modelDirectory = Self.makeModelDirectory()
        let modelManager = ModelManager(modelDirectory: modelDirectory)
        let store: any HistoryStoring
        let queueStore: any ImportQueueStoring
        if let pool = try? AppDatabase.makePool() {
            // `L-008`: must read the *live* setting on every save, not a
            // value captured once at launch — otherwise toggling history on
            // mid-session silently keeps failing saves with
            // `HistoryError.historyDisabled`. `settings.isHistoryEnabledNow`
            // is a `@Sendable` closure over a lock-protected mirror, safe to
            // call from `HistoryStore`'s own actor isolation.
            store = HistoryStore(dbPool: pool, historyEnabled: settings.isHistoryEnabledNow)
            queueStore = ImportQueueStore(dbPool: pool)
        } else {
            store = FailingHistoryStore()
            queueStore = InMemoryImportQueueStore()
        }
        let importManager = ImportManager(
            modelManager: modelManager,
            historyStore: store,
            queueStore: queueStore,
            settings: settings
        )
        _appState = StateObject(wrappedValue: AppState(
            settings: settings,
            modelManager: modelManager,
            historyStore: store,
            importManager: importManager
        ))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(appState)
        } label: {
            // The label is a view SwiftUI keeps alive for the whole app
            // lifetime — it's the natural place to run the one-time launch
            // check. `L-001`/`UI-002`/`AT-001`: if permissions/model aren't
            // in place yet, onboarding must be reachable without the user
            // first knowing to open the menu and find a way in.
            Image(systemName: appState.menuBarSymbolName)
                .foregroundStyle(appState.menuBarSymbolColor)
                .task {
                    // `UI-001`: wire the AppKit-side delegate to this
                    // instance's `appState` and its `openWindow` action
                    // (captured here since `AppDelegate` itself has no
                    // SwiftUI environment access) so Dock-icon "reopen"
                    // clicks with no visible windows can resurface the
                    // right one.
                    windowRouter.openWindowAction = { id in openWindow(id: id) }
                    appDelegate.appState = appState
                    appDelegate.windowRouter = windowRouter

                    appState.applyDockVisibility()
                    appState.refreshReadiness()
                    // VoicePaste normally lives only in the menu bar. The
                    // main window is an explicit destination for history and
                    // statistics, not a side effect of dictation or import.
                    // Onboarding is the sole visible-launch exception.
                    if appState.readiness.state != .ready {
                        openWindow(id: "onboarding")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }

        // `UI-004`/`UI-007`: one permanent window. The menu bar opens its
        // statistics detail; it never becomes a second application window.
        Window("main.window.title", id: "main") {
            MainWindowView()
                .environmentObject(appState)
                .environmentObject(appState.importManager)
        }
        .defaultSize(width: 980, height: 640)
        .windowResizability(.contentMinSize)

        Window("onboarding.window.title", id: "onboarding") {
            OnboardingView()
                .environmentObject(appState)
        }
        .windowResizability(.contentSize)
    }

    private static func makeModelDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("VoicePaste/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
