import AppKit
import Combine
import Foundation
import SwiftUI

/// Which `SettingsView` tab a HUD action (`UI-003`'s "Выбрать микрофон")
/// wants opened next; `SettingsView` consumes and clears this.
public enum SettingsTab: Equatable, Sendable {
    case permissions
}

/// The two destinations of the single permanent application window.
public enum MainContentSection: Hashable, Sendable {
    case history
    case dashboard
    case importQueue
}

/// Central orchestrator wiring `L-001` through `L-008`/`L-010` together:
/// readiness, the global hotkey, audio capture, transcription, normalization,
/// insertion, the HUD, and history. UI (`MenuBarContentView`, `HistoryView`,
/// `SettingsView`, onboarding) only ever talks to this type and to
/// `HistoryStoring`/`ImportManager` — never directly to `AVAudioEngine`,
/// `AXUIElement`, or GRDB.
@MainActor
public final class AppState: ObservableObject {
    public let settings: AppSettings
    public let modelManager: ModelManager
    public let readiness: ReadinessCoordinator
    public let historyStore: any HistoryStoring
    public let importManager: ImportManager
    /// Non-nil only when the durable local database could not be opened or
    /// migrated at launch. Dictation/insertion remain usable, but the main
    /// window must never pretend that history and queue persistence work.
    public let persistenceFailureMessage: String?

    @Published public private(set) var dictationPhase: DictationPhase = .idle
    /// `UI-003` "Выбрать микрофон": set right before opening the Settings
    /// window so it lands on `.permissions` instead of whichever tab was
    /// last shown; `SettingsView` reads and clears it.
    @Published public var requestedSettingsTab: SettingsTab?
    /// `importFinished`'s "Открыть в истории": the record the main window's
    /// sidebar/detail should select next, set right before that window is
    /// brought forward. `HistoryView` reads and clears it, same pattern as
    /// `requestedSettingsTab`.
    @Published public var requestedHistorySelection: UUID?
    /// A menu-bar action can bring the existing main window forward and
    /// select its Statistics view without creating a second app window.
    @Published public var requestedMainContentSection: MainContentSection?

    private var dictationStateMachine: DictationStateMachine
    private let audioCapture = AudioCaptureService()
    private let hud = HUDWindowController()
    private let normalizer = TextNormalizer()
    private var hotkeyManager: HotkeyManager?
    private var frontAppSnapshot: FrontAppSnapshot?
    private var recordingStartedAt: Date?
    private var elapsedBeforePause: TimeInterval = 0
    private var isDictationPaused = false
    private var elapsedTimerTask: Task<Void, Never>?
    private var pausedDictationExpiryTask: Task<Void, Never>?
    /// Both the audio meter (10 Hz) and elapsed timer (5 Hz) ask to refresh
    /// the same HUD. Coalescing guarantees one lightweight SwiftUI update at
    /// most every 100 ms instead of occasionally painting twice in one tick.
    private var lastRecordingHUDRefreshAt = Date.distantPast
    private var currentLevel: Float = 0
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var forwardingCancellables = Set<AnyCancellable>()
    /// Schedules the initial background model warm-up at most once per app
    /// process. A later manual or memory-pressure unload must stay unloaded
    /// until the next real transcription request.
    private var hasScheduledInitialModelPrewarm = false
    /// A ready app may normally become menu-bar-only, but not while its
    /// first-run window is still visible. Changing activation policy at the
    /// exact moment Universal Access is granted otherwise makes the visible
    /// onboarding appear to disappear behind System Settings.
    private var isOnboardingVisible = false

    // MARK: - HUD import drop zone (UI-006, second spec-required surface)

    /// Whether the HUD is currently showing the import drop
    /// zone/progress/result surface rather than dictation content — gates
    /// `importJobCancellable`'s effect and `dismissHUD()`'s cancel-on-close
    /// behavior (`EC-013`).
    private var isImportHUDActive = false
    /// Live `DM-005` progress while `isImportHUDActive`; only reflects the
    /// in-flight phases (`.queued`/`.decoding`/`.transcribing`) — completion
    /// and failure are reported directly by `beginFileImport(url:)`'s own
    /// callbacks, not by observing this job going away.
    private var importJobCancellable: AnyCancellable?
    private var hudImportJobID: UUID?

    public init(
        settings: AppSettings,
        modelManager: ModelManager,
        historyStore: any HistoryStoring,
        importManager: ImportManager,
        persistenceFailureMessage: String? = nil,
        enableGlobalHotkey: Bool = !ProcessRuntime.isRunningTests
    ) {
        self.settings = settings
        self.modelManager = modelManager
        self.readiness = ReadinessCoordinator(modelManager: modelManager)
        self.historyStore = historyStore
        self.importManager = importManager
        self.persistenceFailureMessage = persistenceFailureMessage
        self.dictationStateMachine = DictationStateMachine(mode: settings.recordingMode)

        importManager.restoreQueue()

        // Views only hold `@EnvironmentObject var appState: AppState` — a
        // nested `ObservableObject`'s own `@Published` changes (readiness
        // status, model download progress) don't automatically propagate to
        // *this* object's `objectWillChange`, so without forwarding, neither
        // the menu-bar icon nor onboarding's status labels/progress bar would
        // ever redraw after the initial render (`L-001`, `UI-002`).
        self.readiness.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &forwardingCancellables)
        self.modelManager.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &forwardingCancellables)
        // The import queue is nested for ownership reasons, but both its
        // right-side workspace and the small queue line in Statistics must
        // redraw for every staged/progress/completion update.
        self.importManager.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &forwardingCancellables)

        // Test hosts never register a real global shortcut. The shipped app
        // uses the default (`true`); tests explicitly opt out.
        if enableGlobalHotkey {
            let manager = HotkeyManager(shortcut: settings.hotkey) { [weak self] phase in
                switch phase {
                case .down: self?.handleHotkeyDown()
                case .up: self?.handleHotkeyUp()
                }
            } onEscape: { [weak self] in
                self?.cancelDictationWithEscape()
            }
            self.hotkeyManager = manager
        }

        audioCapture.onLevel = { [weak self] level in
            self?.currentLevel = level
            self?.refreshRecordingHUD()
        }

        // `UI-003`: the HUD's mouse controls call back into the same
        // dictation logic the hotkey/menu drive — never a separate path.
        hud.configureActions(
            onFinish: { [weak self] in self?.finishDictationFromHUD() },
            onCancel: { [weak self] in self?.cancelDictationFromHUD() },
            onRetry: { [weak self] in self?.retryDictationFromHUD() },
            onSelectMicrophone: { [weak self] in self?.openSettingsToPermissions() },
            onDismiss: { [weak self] in self?.dismissHUD() },
            onImportFileDropped: { [weak self] url in self?.beginFileImport(url: url) },
            onChooseImportFile: { [weak self] in self?.chooseFileForImportFromHUD() },
            onOpenHistoryRecord: { [weak self] id in self?.openHistoryRecord(id) },
            onSwitchToImport: { [weak self] in self?.switchToFileImportFromHUD() },
            onResumeRecording: { [weak self] in self?.resumeDictationAfterEscape() },
            onImportResultCopied: { [weak self] in self?.presentHUD(.copied) },
            onImportResultOpened: { [weak self] in self?.presentHUD(.importOpened) },
            onCancelPausedDictation: { [weak self] in self?.cancelPausedDictationFromHUD() }
        )

        // `L-001`: the user grants mic/Accessibility access in System
        // Settings, a *different* app, then switches back to us — that's a
        // normal app activation, not a workspace-wide app-switch. Without
        // this, `readiness.state` (and the menu-bar icon color/onboarding
        // labels that read it) stays stale until the app is relaunched.
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshReadiness()
            }
        }
    }

    /// Call after any Settings change (`AT-011`, mode switch) and whenever
    /// returning from System Settings (permission status may have changed).
    public func settingsDidChange() {
        dictationStateMachine.mode = settings.recordingMode
        hotkeyManager?.updateShortcut(settings.hotkey)
    }

    /// Switch between normal Dock presence and a menu-bar-only resident app
    /// without restarting. `INV-015`/`AT-089`: while the app isn't `ready`
    /// yet, it is forced `.regular` (visible in the Dock) regardless of the
    /// saved `showInDock` preference — this is the single call site that
    /// ever mutates `activationPolicy`; nothing else in the app calls
    /// `setActivationPolicy` directly.
    public func applyDockVisibility() {
        let policy: NSApplication.ActivationPolicy
        if readiness.state != .ready || isOnboardingVisible {
            policy = .regular
        } else {
            policy = settings.showInDock ? .regular : .accessory
        }
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }

    /// Called by the single onboarding window's lifecycle. This keeps the
    /// normal `showInDock` preference intact while preventing a permission
    /// update from hiding the window that is explaining the next step.
    public func setOnboardingVisible(_ isVisible: Bool) {
        guard isOnboardingVisible != isVisible else { return }
        isOnboardingVisible = isVisible
        applyDockVisibility()
    }

    /// `L-001`: the single place that recomputes `readiness.state` also
    /// re-applies the Dock policy that state gates (`AT-089`) and the
    /// registered-hotkey readiness gate (`AT-090`) — callers never need to
    /// remember to do either separately, so a permission-granted /
    /// model-ready transition takes effect without a restart.
    public func refreshReadiness() {
        readiness.refresh()
        let isReady = readiness.state == .ready
        hotkeyManager?.setSystemSwallowEnabled(isReady)
        // `L-010`/`AT-099`: the verified on-disk model should become resident
        // as soon as onboarding/permissions make the app usable, not only
        // after the user has already finished their first recording.
        // This one-shot process guard also preserves an explicit later unload.
        // `ensureLoaded()` is single-flight, so dictation started while the
        // warm-up is running joins that same load. The actual WhisperKit/Core
        // ML work runs on its own executor; this MainActor call only schedules
        // it and returns immediately.
        if isReady, !hasScheduledInitialModelPrewarm {
            hasScheduledInitialModelPrewarm = true
            modelManager.prewarm()
        }
        applyDockVisibility()
    }

    // MARK: - Menu bar icon (UI-001)

    public var menuBarSymbolName: String {
        switch dictationPhase {
        case .recording: return "waveform.circle.fill"
        case .processing: return "ellipsis.circle"
        case .idle:
            return readiness.state == .ready ? "waveform" : "exclamationmark.triangle"
        }
    }

    public var menuBarSymbolColor: Color {
        switch dictationPhase {
        case .recording: return .red
        case .processing: return .secondary
        case .idle: return readiness.state == .ready ? .primary : .red
        }
    }

    // MARK: - Hotkey / toggle+hold state machine (L-002/L-003, EC-003)

    public func handleHotkeyDown() {
        if isDictationPaused {
            resumeDictationAfterEscape()
            return
        }
        if dictationStateMachine.phase == .idle, readiness.state != .ready {
            presentNotReadyMessage()
            return
        }
        apply(dictationStateMachine.handleHotkeyDown())
    }

    public func handleHotkeyUp() {
        guard !isDictationPaused else { return }
        apply(dictationStateMachine.handleHotkeyUp())
    }

    private func apply(_ effect: DictationEffect) {
        switch effect {
        case .startCapture:
            beginRecording()
        case .stopCaptureAndProcess:
            endRecordingAndProcess()
        case .cancelCapture:
            cancelRecording()
        case .alreadyProcessing:
            // EC-003: keep the running job, just say so.
            presentHUD(.error(
                message: NSLocalizedString("dictation.alreadyProcessing", comment: "")
            ))
        case .none:
            break
        }
        synchronizeDictationPhase()
    }

    private func presentNotReadyMessage() {
        // Logged with the *reason*, not just "an error appeared": this plaque
        // is what the user actually sees when dictation refuses to start, and
        // without the readiness state behind it the log said nothing useful.
        Task {
            await DiagnosticLog.shared.log(
                "dictation.notReady",
                detail: ReadinessCoordinator.describe(readiness.state)
            )
        }
        presentHUD(.error(
            message: NSLocalizedString(readiness.state.statusLocalizationKey, comment: "")
        ))
    }

    // MARK: - Recording (L-004, DEP-003)

    private func beginRecording() {
        frontAppSnapshot = TextInserter.captureFrontAppSnapshot()
        // `L-010`: start loading the model the moment recording begins, so it
        // warms up *while the user is still speaking* if the one-time launch
        // warm-up has not completed (or the model was later unloaded).
        // `ensureLoaded()` coalesces, so the transcription that follows joins
        // this same load rather than starting a second one.
        modelManager.prewarm()
        do {
            try audioCapture.start()
        } catch {
            dictationStateMachine.handleProcessingFinished()
            dictationPhase = .idle
            // `dictation.microphoneError`'s single relevant recovery is
            // picking a working input device in Settings → Разрешения.
            presentHUD(.error(
                message: NSLocalizedString("dictation.microphoneError", comment: ""),
                action: .selectMicrophone
            ))
            Task { await DiagnosticLog.shared.log("capture.start.failed", detail: String(describing: error)) }
            return
        }
        recordingStartedAt = Date()
        elapsedBeforePause = 0
        isDictationPaused = false
        pausedDictationExpiryTask?.cancel()
        // Present synchronously after successful capture. The ticker is only
        // for subsequent elapsed/level updates; waiting for its task turn
        // made the HUD vulnerable to being visually missed under load.
        refreshRecordingHUD(force: true)
        startElapsedTicker()
    }

    private func startElapsedTicker() {
        elapsedTimerTask?.cancel()
        elapsedTimerTask = Task { [weak self] in
            while let self, self.dictationStateMachine.phase == .recording, !Task.isCancelled {
                self.refreshRecordingHUD()
                // TOK-hud.recording-updates — не более десяти обновлений в секунду.
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func refreshRecordingHUD(force: Bool = false) {
        guard dictationStateMachine.phase == .recording,
              !isDictationPaused,
              let startedAt = recordingStartedAt else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastRecordingHUDRefreshAt) >= 0.1 else { return }
        lastRecordingHUDRefreshAt = now
        presentHUD(.recording(
            elapsed: elapsedBeforePause + now.timeIntervalSince(startedAt),
            level: currentLevel
        ))
    }

    /// `UI-003` HUD "Отменить" button (mode-independent, works alongside the
    /// hotkey): stops capture and discards the buffer outright — no
    /// transcription is ever started and no history row is written, unlike
    /// `endRecordingAndProcess()`.
    private func cancelRecording(showUndo: Bool = false) {
        discardRecording()
        presentHUD(showUndo ? .cancelledWithUndo : .cancelled)
    }

    private func discardRecording() {
        elapsedTimerTask?.cancel()
        pausedDictationExpiryTask?.cancel()
        _ = audioCapture.stop() // discarded on purpose: cancel means no transcription, no history
        frontAppSnapshot = nil
        recordingStartedAt = nil
        elapsedBeforePause = 0
        isDictationPaused = false
        currentLevel = 0
        lastRecordingHUDRefreshAt = .distantPast
    }

    /// `UI-003` HUD "Готово"/✓ button.
    public func finishDictationFromHUD() {
        apply(dictationStateMachine.finishFromUI())
    }

    /// `UI-003` HUD "Отменить"/✕ button.
    public func cancelDictationFromHUD() {
        apply(dictationStateMachine.cancelFromUI())
    }

    /// Escape pauses capture without draining its buffer. The return arrow
    /// resumes into the same accumulator; only the explicit × control truly
    /// discards a recording.
    public func cancelDictationWithEscape() {
        guard dictationStateMachine.phase == .recording, !isDictationPaused else { return }
        elapsedTimerTask?.cancel()
        if let recordingStartedAt {
            elapsedBeforePause += Date().timeIntervalSince(recordingStartedAt)
        }
        self.recordingStartedAt = nil
        audioCapture.pause()
        isDictationPaused = true
        hotkeyManager?.setEscapeCancellationEnabled(false)
        presentHUD(.cancelledWithUndo)
        pausedDictationExpiryTask?.cancel()
        pausedDictationExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.cancelPausedDictationFromHUD()
        }
    }

    /// File mode is a true mode switch: current microphone audio is discarded
    /// and the capture engine is stopped before the drop target is shown.
    public func switchToFileImportFromHUD() {
        if dictationStateMachine.phase == .recording {
            _ = dictationStateMachine.cancelFromUI()
            synchronizeDictationPhase()
            discardRecording()
        }
        presentImportHUD()
    }

    /// The curved-arrow control after Escape reconnects a fresh mic engine
    /// to the existing accumulator, preserving everything said before pause.
    public func resumeDictationAfterEscape() {
        guard dictationStateMachine.phase == .recording, isDictationPaused else { return }
        do {
            try audioCapture.resume()
            isDictationPaused = false
            pausedDictationExpiryTask?.cancel()
            recordingStartedAt = Date()
            hotkeyManager?.setEscapeCancellationEnabled(true)
            refreshRecordingHUD(force: true)
            startElapsedTicker()
        } catch {
            _ = dictationStateMachine.cancelFromUI()
            synchronizeDictationPhase()
            discardRecording()
            presentHUD(.error(
                message: NSLocalizedString("dictation.microphoneError", comment: ""),
                action: .selectMicrophone
            ))
        }
    }

    /// The × shown while Escape-paused is the irreversible branch: discard
    /// all captured audio and return to idle. It is deliberately distinct
    /// from the curved return arrow, which resumes the same buffer.
    public func cancelPausedDictationFromHUD() {
        guard dictationStateMachine.phase == .recording, isDictationPaused else { return }
        _ = dictationStateMachine.cancelFromUI()
        synchronizeDictationPhase()
        cancelRecording()
    }

    /// `UI-003` error-state "Повторить" button: starts a fresh session the
    /// same way a hotkey press from `.idle` would (readiness is re-checked
    /// there, same as any other hotkey-down).
    public func retryDictationFromHUD() {
        handleHotkeyDown()
    }

    /// `UI-003` error-state "Выбрать микрофон" button: opens this app's own
    /// Settings window to the Разрешения tab. Unlike the HUD's own buttons,
    /// this deliberately *does* activate VoicePaste and steal focus — by
    /// this point the dictation session already ended (successfully or not),
    /// so there is no pending insertion whose target focus needs preserving.
    public func openSettingsToPermissions() {
        requestedSettingsTab = .permissions
        openSettings()
    }

    /// `UI-001`/`AT-087`/`AT-091`: the menu bar's "Настройки…" item must
    /// reach the front and gain focus even in menu-bar-only (`.accessory`)
    /// mode, and it must open the *Settings* window specifically — never the
    /// main window (history), which `NSApp.activate` alone can otherwise
    /// raise first if it happens to already be open. Activating here does
    /// *not* change `activationPolicy` — the Dock icon stays as
    /// `applyDockVisibility()` last set it; the app only becomes momentarily
    /// active to present its own window, same `NSApp.activate` mechanism used
    /// by `openMainOrOnboarding(section:)` below. The actual window is opened through the
    /// documented `@Environment(\.openSettings)` action, captured once at
    /// launch into `WindowRouter` the same way `openWindow` is (`App.swift`),
    /// not by sending the private `showSettingsWindow:` selector.
    public func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        WindowRouter.shared.openSettings()
    }

    /// `UI-003` error-state "×" close button: dismisses the HUD without
    /// waiting out its auto-dismiss timer. Also the HUD import surface's
    /// close button (`UI-006`): if a file is still importing when the user
    /// closes it, the job is cancelled outright so no work keeps running
    /// against a panel nobody can see anymore (`EC-013` — "отмена
    /// освобождает ресурсы").
    public func dismissHUD() {
        if isImportHUDActive {
            if let hudImportJobID { importManager.cancel(id: hudImportJobID) }
            endImportHUDObservation()
        }
        hud.hide()
    }

    /// `importFinished`'s "Открыть в истории": brings the main window
    /// forward and asks it to select this specific saved record. Unlike the
    /// HUD's own dismiss/cancel/retry buttons, this deliberately *does*
    /// activate VoicePaste — by this point the import already finished, so
    /// there is no pending insertion whose target focus needs preserving.
    public func openHistoryRecord(_ id: UUID) {
        requestedHistorySelection = id
        openMainOrOnboarding(section: .history)
    }

    public func openStatistics() {
        openMainOrOnboarding(section: .dashboard)
    }

    public func openImportQueue() {
        openMainOrOnboarding(section: .importQueue)
    }

    /// `INV-015`/`AT-088`/`AT-089` single router: every entry point that
    /// wants the app's one permanent window — the menu bar's "Открыть
    /// VoicePaste"/"Статистика", the HUD's "Открыть в истории"/import-queue
    /// hand-offs, and the Dock-icon reopen gesture (`AppDelegate`) — funnels
    /// through here instead of calling `WindowRouter.open("main")` directly,
    /// so they can never again drift out of sync on whether onboarding must
    /// intervene first. While `readiness.state != .ready`, onboarding is the
    /// only reachable window (`main` never opens, empty or otherwise); once
    /// ready, `section` is applied and `main` opens as requested.
    public func openMainOrOnboarding(section: MainContentSection) {
        NSApp.activate(ignoringOtherApps: true)
        guard readiness.state == .ready else {
            WindowRouter.shared.open("onboarding")
            return
        }
        requestedMainContentSection = section
        WindowRouter.shared.open("main")
    }

    // MARK: - HUD import (UI-006)

    /// Menu bar "Транскрибировать файл…" (`UI-001`): raises the HUD as a
    /// drop target waiting for a file. Any other in-progress HUD content
    /// (recording, a status plaque) is replaced, same as any other
    /// `presentHUD` call.
    public func presentImportHUD() {
        hud.present(.importIdle)
    }

    /// The raised import surface is useful even without dragging: clicking
    /// its explicit placeholder opens the same native file picker as the
    /// main-window toolbar, then continues through the identical HUD flow.
    public func chooseFileForImportFromHUD() {
        // The HUD is deliberately a non-activating panel, which is right for
        // dictation but means an `NSOpenPanel` begun from it can end up behind
        // the active app. File import has no pending text target, so making
        // VoicePaste active for the system picker is both safe and expected.
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ImportPanelPresenter.allowedContentTypes
        DispatchQueue.main.async {
            panel.begin { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                self?.beginFileImport(url: url)
            }
        }
    }

    /// Queue a file from the main import detail. This path deliberately does
    /// not activate or show the transient HUD — the detail itself is the
    /// progress surface.
    @discardableResult
    public func enqueueFileImport(_ url: URL) -> UUID {
        importManager.enqueue(url: url)
    }

    /// HUD import is only the compact alternative trigger. It enqueues the
    /// same persistent job as the main detail and observes its own id, never
    /// cancelling unrelated queued work.
    public func beginFileImport(url: URL) {
        isImportHUDActive = true
        importJobCancellable?.cancel()
        // Shown immediately (not left blank) to cover the brief `async` gap
        // before `currentJob` actually exists (vocabulary fetch, `L-006`).
        hud.present(.importing)

        // Let the drag-and-drop event return before creating the import task.
        // This gives AppKit one run-loop turn to animate the compact
        // "Расшифровка…" state instead of visibly stalling the dropped file.
        let jobID = importManager.enqueue(url: url)
        hudImportJobID = jobID
        importJobCancellable = Publishers.CombineLatest(importManager.$jobs, importManager.$lastCompletion)
            .receive(on: RunLoop.main)
            .sink { [weak self] jobs, completion in
                guard let self, self.isImportHUDActive, self.hudImportJobID == jobID else { return }
                if let completion, completion.jobID == jobID {
                    self.endImportHUDObservation()
                    self.hud.present(.importFinished(text: completion.transcript.text, transcriptID: completion.transcript.id))
                    return
                }
                if let failed = jobs.first(where: { $0.id == jobID && $0.state == .failed }) {
                    self.endImportHUDObservation()
                    self.hud.present(.error(message: NSLocalizedString(failed.failureKey ?? "import.error.transcriptionFailed", comment: "")))
                }
            }
    }

    /// Stops the progress subscription without necessarily hiding the HUD —
    /// used once a terminal state (result/error) has already been presented,
    /// so a stray `currentJob` tick from an unrelated import elsewhere can
    /// never overwrite it.
    private func endImportHUDObservation() {
        importJobCancellable?.cancel()
        importJobCancellable = nil
        isImportHUDActive = false
        hudImportJobID = nil
    }

    private func synchronizeDictationPhase() {
        dictationPhase = dictationStateMachine.phase
        hotkeyManager?.setEscapeCancellationEnabled(dictationPhase == .recording && !isDictationPaused)
    }

    /// Every other HUD presentation path (dictation recording/processing/
    /// status plaques) — routes through here instead of calling
    /// `hud.present` directly so switching away from the import surface
    /// always tears down its progress subscription first.
    private func presentHUD(_ state: HUDState) {
        endImportHUDObservation()
        hud.present(state)
    }

    // MARK: - Stop + transcribe (L-005/L-006/L-007/L-008, EC-004/EC-005)

    private func endRecordingAndProcess() {
        elapsedTimerTask?.cancel()
        let samples = audioCapture.stop()

        // A very short buffer has too little phonetic context for Whisper and
        // can produce plausible-looking hallucinations such as "Продолжение
        // следует…". Reject it before the model sees it: a quick accidental
        // double-tap is not a transcription request. Crucially, this check
        // happens *before* `.processing` is presented, so the existing HUD
        // morphs directly from recording to its compact error without a
        // visible shrink-then-grow intermediate state.
        let minimumSamples = 8_000 // 0.5 s at the 16 kHz capture format
        // 0.004 RMS retains quiet human speech but rejects microphone floor
        // noise / silence. The decision is derived during capture, not by a
        // second scan over the full buffer on the main actor.
        let minimumSpeechRMS: Float = 0.004
        guard samples.count >= minimumSamples, audioCapture.lastCaptureRMS >= minimumSpeechRMS else {
            dictationStateMachine.handleProcessingFinished()
            dictationPhase = .idle
            // `dictation.emptyAudio`'s single relevant recovery is trying
            // again immediately.
            presentHUD(.error(
                message: NSLocalizedString("dictation.emptyAudio", comment: "")
            ))
            return
        }

        presentHUD(.processing)

        Task { [weak self] in
            await self?.transcribeAndFinish(samples: samples)
        }
    }

    private func transcribeAndFinish(samples: [Float]) async {
        defer {
            dictationStateMachine.handleProcessingFinished()
            dictationPhase = .idle
            frontAppSnapshot = nil
        }

        do {
            let engine = try await modelManager.ensureLoaded()
            let request = TranscriptionRequest(samples: samples, language: settings.languageMode)
            let result = try await engine.transcribe(request)

            let vocabulary = (try? await historyStore.fetchVocabulary()) ?? []
            let (normalizedText, _) = await normalizer.normalizeInBackground(
                rawText: result.rawText,
                language: settings.languageMode,
                vocabulary: vocabulary,
                autoCorrectSafeTypos: settings.autoCorrectSafeTypos
            )

            var outcome: Transcript.InsertionOutcome = .notRequested
            if settings.autoInsertEnabled {
                let inserter = TextInserter()
                outcome = inserter.insert(normalizedText, into: frontAppSnapshot) == .inserted ? .inserted : .copied
            } else {
                // "Не вставлять автоматически" is a deliberate clipboard
                // workflow, never a silent discard of the finished text.
                TextInserter.copyToClipboard(normalizedText)
                outcome = .copied
            }

            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            let transcript = Transcript(
                id: UUID(),
                createdAt: now,
                updatedAt: now,
                source: .dictation,
                sourceFileName: nil,
                durationMilliseconds: Int(Double(samples.count) / 16_000.0 * 1_000),
                language: result.detectedLanguage,
                rawText: result.rawText,
                text: normalizedText,
                preview: Transcript.makePreview(from: normalizedText),
                status: .completed,
                insertionOutcome: outcome
            )

            if settings.historyEnabled {
                try? await historyStore.save(transcript)
            }
            modelManager.endTask(unloadMinutes: settings.modelUnloadMinutes)

            switch outcome {
            case .inserted: presentHUD(.inserted)
            case .copied: presentHUD(.copied)
            case .notRequested: presentHUD(.hidden)
            }
        } catch {
            modelManager.endTask(unloadMinutes: settings.modelUnloadMinutes)
            presentHUD(.error(
                message: NSLocalizedString("dictation.transcriptionFailed", comment: "")
            ))
            Task { await DiagnosticLog.shared.log("dictation.transcriptionFailed", detail: String(describing: error)) }
        }
    }

    // MARK: - Lifecycle (EC-014, L-010/L-011)

    /// App quit: releases the model unconditionally (`L-010`).
    public func prepareForQuit() {
        _ = audioCapture.stop()
        hotkeyManager?.stop()
        modelManager.unloadNow()
    }
}

/// XCTest currently uses VoicePaste itself as its test host. Every system
/// integration is therefore disabled by default for *every* test invocation
/// — not only for fixtures that remember to pass a constructor argument.
/// The production app has neither XCTest environment variable nor class, so
/// its default remains the real global hotkey.
public enum ProcessRuntime {
    public nonisolated static let isRunningTests: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["VOICEPASTE_TEST_HOST"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()
}
