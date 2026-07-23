import AppKit
import SwiftUI

@main
struct VoicePasteApp: App {
    @StateObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let windowRouter = WindowRouter.shared

    init() {
        let isRunningTests = ProcessRuntime.isRunningTests
        let settings: AppSettings
        let modelInstallation: ModelInstallation
        if isRunningTests {
            let defaults = UserDefaults(suiteName: "VoicePaste-TestHost-\(UUID().uuidString)")!
            settings = AppSettings(defaults: defaults)
            modelInstallation = ModelInstallation(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("VoicePaste-TestHost-\(UUID().uuidString)", isDirectory: true),
                isBundled: false
            )
        } else {
            settings = AppSettings()
            modelInstallation = Self.resolveModelInstallation()
        }
        let modelManager = ModelManager(
            modelDirectory: modelInstallation.directory,
            downloadEndpointProvider: { settings.modelDownloadEndpoint },
            downloadSourceProvider: { settings.modelDownloadSource },
            allowsNetworkDownloads: !modelInstallation.isBundled,
            isBundledModel: modelInstallation.isBundled
        )
        let store: any HistoryStoring
        let queueStore: any ImportQueueStoring
        let persistenceFailureMessage: String?
        if isRunningTests {
            // XCTest loads the product as TEST_HOST. Never touch the user's
            // database, queue, preferences or Application Support merely by
            // compiling/running a unit test bundle.
            store = FailingHistoryStore()
            queueStore = InMemoryImportQueueStore()
            persistenceFailureMessage = nil
        } else {
            do {
                let pool = try AppDatabase.makePool()
                // `L-008`: must read the *live* setting on every save, not a
                // value captured once at launch — otherwise toggling history on
                // mid-session silently keeps failing saves with
                // `HistoryError.historyDisabled`. `settings.isHistoryEnabledNow`
                // is a `@Sendable` closure over a lock-protected mirror, safe to
                // call from `HistoryStore`'s own actor isolation.
                store = HistoryStore(dbPool: pool, historyEnabled: settings.isHistoryEnabledNow)
                queueStore = ImportQueueStore(dbPool: pool)
                persistenceFailureMessage = nil
            } catch {
                store = FailingHistoryStore()
                queueStore = InMemoryImportQueueStore()
                let failureDetail = String(describing: error)
                persistenceFailureMessage = failureDetail
                Task {
                    await DiagnosticLog.shared.log(
                        "persistence.openFailed",
                        detail: failureDetail
                    )
                }
            }
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
            importManager: importManager,
            persistenceFailureMessage: persistenceFailureMessage
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
                    guard !ProcessRuntime.isRunningTests else { return }
                    // `UI-001`: wire the AppKit-side delegate to this
                    // instance's `appState` and its `openWindow`/`openSettings`
                    // actions (captured here since `AppDelegate` itself has no
                    // SwiftUI environment access, and `AppState.openSettings()`
                    // has none either) so Dock-icon "reopen" clicks with no
                    // visible windows, and the menu bar's "Настройки…", can
                    // resurface the right window (`AT-091`).
                    windowRouter.openWindowAction = { id in openWindow(id: id) }
                    windowRouter.openSettingsAction = { openSettings() }
                    appDelegate.appState = appState
                    appDelegate.windowRouter = windowRouter

                    // `L-001`/`UI-002`: the model's on-disk check runs in the
                    // background from `ModelManager.init`. Until it reports
                    // back, model state is `.notPrepared` — i.e. readiness says
                    // "нужна загрузка модели" even on a machine where the model
                    // has been installed for weeks. Deciding about onboarding
                    // before that lands is a race that can pop the first-run
                    // window in a fully-configured user's face; awaiting it
                    // makes the launch decision deterministic.
                    await appState.modelManager.awaitInitialModelDiscovery()

                    // `INV-015`/`AT-089`: `refreshReadiness()` both computes
                    // `readiness.state` and applies the Dock policy it gates
                    // (`applyDockVisibility()`, called from inside it) — a
                    // single call, no separate policy application here, so
                    // there's no window where the two could disagree.
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

    private struct ModelInstallation {
        let directory: URL
        let isBundled: Bool
    }

    /// A release produced by `build-offline-release.sh` contains the model
    /// under Resources/VoicePasteModels. Its mere presence selects strict
    /// offline policy: a corrupt bundle must not fall back to the network.
    /// Development builds without that resource keep the existing external
    /// model directory so tests and local iteration remain lightweight.
    private static func resolveModelInstallation() -> ModelInstallation {
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("VoicePasteModels", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.path) {
            return ModelInstallation(directory: bundled, isBundled: true)
        }

        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("VoicePaste/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ModelInstallation(directory: directory, isBundled: false)
    }
}
