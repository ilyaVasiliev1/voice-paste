import AppKit
import XCTest
@testable import VoicePaste

/// Integration coverage for `INV-015`/`AT-088`/`AT-089`/`AT-091`'s
/// deterministic half — the routing/policy *decision* that does not depend
/// on a real hotkey, microphone, or signed installed `.app`.
///
/// `ReadinessCoordinator.state` cannot be forced to `.ready` from a test:
/// it derives from real `AVCaptureDevice.authorizationStatus`/
/// `AXIsProcessTrusted()` (never granted to the `xcodebuild test` runner
/// process, same reasoning as `HotkeyManagerTests`), gated *before* the
/// model check. But every `AppState` built here also points `ModelManager`
/// at a fresh, empty temp directory, which independently guarantees
/// `.notPrepared`/never `.ready` (see `ModelManagerTests
/// .test_init_withEmptyModelDirectory_startsNotPrepared`). Combined, the two
/// guarantee `readiness.state != .ready` regardless of the host Mac's TCC
/// grants for this bundle ID — this is the honestly-testable half of
/// AT-088/089; the ready-path branches (full main window, `showInDock`
/// applied, hotkey actually swallowed) remain `живой smoke` per
/// `spec/_tests.md`'s proof-mode matrix.
@MainActor
final class AppStateRoutingTests: XCTestCase {

    private func makeAppState(showInDock: Bool = true) throws -> AppState {
        let suiteName = "AppStateRoutingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = AppSettings(defaults: defaults)
        settings.showInDock = showInDock

        let modelDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStateRoutingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: modelDirectory) }
        let modelManager = ModelManager(
            modelDirectory: modelDirectory,
            makeTranscriber: { _, _ in MockTranscriber(result: .success(.init(rawText: "", detectedLanguage: nil))) }
        )

        let historyStore = FailingHistoryStore()
        let importManager = ImportManager(
            modelManager: modelManager,
            historyStore: historyStore,
            queueStore: InMemoryImportQueueStore(),
            settings: settings
        )

        let appState = AppState(
            settings: settings,
            modelManager: modelManager,
            historyStore: historyStore,
            importManager: importManager
        )
        // Sanity precondition every test in this file relies on: without it,
        // any assertion below would be meaningless (see the class doc).
        XCTAssertNotEqual(appState.readiness.state, .ready, "fixture precondition: must be guaranteed not-ready")
        return appState
    }

    /// Saves/restores the shared `WindowRouter` around a test body. The
    /// singleton is also wired by the real, running `VoicePasteApp` instance
    /// hosting this test bundle (`TEST_HOST`), so tests must not leave their
    /// spy installed afterward.
    private func withWindowRouterSpy(
        _ body: (_ openedWindowIDs: () -> [String], _ settingsOpenCount: () -> Int) throws -> Void
    ) rethrows {
        let router = WindowRouter.shared
        let previousOpenWindow = router.openWindowAction
        let previousOpenSettings = router.openSettingsAction
        defer {
            router.openWindowAction = previousOpenWindow
            router.openSettingsAction = previousOpenSettings
        }

        var openedWindowIDs: [String] = []
        var settingsOpenCount = 0
        router.openWindowAction = { id in openedWindowIDs.append(id) }
        router.openSettingsAction = { settingsOpenCount += 1 }

        try body({ openedWindowIDs }, { settingsOpenCount })
    }

    // MARK: - AT-088: linear gating before readiness

    /// `openMainOrOnboarding` is the single router behind "Открыть VoicePaste"
    /// and "Статистика" (`AppState.openStatistics`). While not ready it must
    /// route to onboarding and must never set `requestedMainContentSection`
    /// to a main-window section — regression this catches: main window
    /// silently reachable (even empty) before permissions/model are ready.
    func test_openStatistics_whenNotReady_routesToOnboarding_notMainSection() throws {
        let appState = try makeAppState()

        withWindowRouterSpy { openedWindowIDs, _ in
            appState.openStatistics()

            XCTAssertNil(appState.requestedMainContentSection, "must not select a main-window section before ready")
            XCTAssertEqual(openedWindowIDs(), ["onboarding"], "must open onboarding, not main")
        }
    }

    func test_openImportQueue_whenNotReady_routesToOnboarding_notMainSection() throws {
        let appState = try makeAppState()

        withWindowRouterSpy { openedWindowIDs, _ in
            appState.openImportQueue()

            XCTAssertNil(appState.requestedMainContentSection)
            XCTAssertEqual(openedWindowIDs(), ["onboarding"])
        }
    }

    /// The HUD's "Открыть в истории" hand-off (`openHistoryRecord`) sets the
    /// requested selection independently of readiness, but must still be
    /// gated the same way for the *window* it opens: no main window before
    /// ready, even with a pending selection queued up.
    func test_openHistoryRecord_whenNotReady_routesToOnboarding_notMainSection() throws {
        let appState = try makeAppState()
        let recordID = UUID()

        withWindowRouterSpy { openedWindowIDs, _ in
            appState.openHistoryRecord(recordID)

            XCTAssertNil(appState.requestedMainContentSection)
            XCTAssertEqual(openedWindowIDs(), ["onboarding"])
        }
    }

    /// Directly exercises the shared router for every `MainContentSection`
    /// case, guarding against a future case being added without wiring it
    /// through the not-ready gate.
    func test_openMainOrOnboarding_whenNotReady_neverOpensMain_forAnySection() throws {
        let appState = try makeAppState()

        for section: MainContentSection in [.history, .dashboard, .importQueue] {
            withWindowRouterSpy { openedWindowIDs, _ in
                appState.openMainOrOnboarding(section: section)

                XCTAssertNil(appState.requestedMainContentSection)
                XCTAssertEqual(openedWindowIDs(), ["onboarding"])
            }
        }
    }

    /// AT-088's disabled-controls half: `HistoryView` gates recording/import
    /// toolbar buttons with `.disabled(appState.readiness.state != .ready)`
    /// (see `VoicePaste/UI/History/HistoryView.swift`). The rendered SwiftUI
    /// disabled state itself is not inspectable headlessly (`живой smoke`),
    /// but the boolean condition driving it is exactly this published value —
    /// pinned here so a future readiness refactor can't silently flip it.
    func test_readinessState_whenNotReady_isNotEqualToReady_drivesHistoryViewDisabled() throws {
        let appState = try makeAppState()

        XCTAssertTrue(appState.readiness.state != .ready)
    }

    // MARK: - AT-089: forced `.regular` while not ready

    /// `applyDockVisibility()` must force `.regular` while not ready
    /// regardless of `showInDock` — regression this catches: dropping the
    /// `readiness.state != .ready` branch (or short-circuiting straight to
    /// `showInDock ? .regular : .accessory`) would leave the app `.accessory`
    /// (invisible in the Dock) during onboarding, exactly the AT-089 dead end.
    func test_applyDockVisibility_whenNotReady_forcesRegular_evenWithShowInDockFalse() throws {
        let appState = try makeAppState(showInDock: false)
        NSApp.setActivationPolicy(.accessory) // simulate a leftover menu-bar-only policy

        appState.applyDockVisibility()

        XCTAssertEqual(NSApp.activationPolicy(), .regular)
    }

    func test_applyDockVisibility_whenNotReady_staysRegular_withShowInDockTrue() throws {
        let appState = try makeAppState(showInDock: true)
        NSApp.setActivationPolicy(.accessory)

        appState.applyDockVisibility()

        XCTAssertEqual(NSApp.activationPolicy(), .regular)
    }

    // MARK: - AT-091: "Настройки…" mechanism never opens main

    /// `openSettings()` must always go through `WindowRouter.openSettings()`
    /// (the documented `@Environment(\.openSettings)` action captured at
    /// launch) and never through `openWindowAction("main")` — regression
    /// this catches: a future edit routing "Настройки…" through the same
    /// `open(_:)` call used for history/statistics, which could let an
    /// already-open main window win the focus race instead of Settings.
    func test_openSettings_callsOpenSettingsAction_neverOpensMainWindow() throws {
        let appState = try makeAppState()

        withWindowRouterSpy { openedWindowIDs, settingsOpenCount in
            appState.openSettings()

            XCTAssertEqual(settingsOpenCount(), 1)
            XCTAssertEqual(openedWindowIDs(), [], "must not open any window via openWindowAction")
        }
    }

    /// Same mechanism check repeated to simulate "History window already
    /// open, then Настройки… chosen again" (`AT-091`'s second scenario) at
    /// the level this test can reach: the call is idempotent and still never
    /// touches `openWindowAction`. Whether an already-open main window can
    /// visually steal focus back is a real window-server behavior only a
    /// живой smoke on the installed `.app` can confirm.
    func test_openSettings_calledRepeatedly_stillNeverOpensMainWindow() throws {
        let appState = try makeAppState()

        withWindowRouterSpy { openedWindowIDs, settingsOpenCount in
            appState.openSettings()
            appState.openSettings()

            XCTAssertEqual(settingsOpenCount(), 2)
            XCTAssertEqual(openedWindowIDs(), [])
        }
    }
}
