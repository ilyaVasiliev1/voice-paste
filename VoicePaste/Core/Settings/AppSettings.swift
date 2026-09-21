import Foundation
import ServiceManagement

/// `DM-001` — the single small-footprint settings record, backed by
/// `UserDefaults`. Every default below mirrors `data-model.md` exactly.
@MainActor
public final class AppSettings: ObservableObject {
    private enum Keys {
        static let hotkey = "hotkey"
        static let recordingMode = "recordingMode"
        static let modelUnloadMinutes = "modelUnloadMinutes"
        static let historyEnabled = "historyEnabled"
        static let autoInsertEnabled = "autoInsertEnabled"
        static let autoCorrectSafeTypos = "autoCorrectSafeTypos"
        static let languageMode = "languageMode"
        static let showInDock = "showInDock"
        static let modelDownloadSource = "modelDownloadSource"
        static let lectureParagraphPauseSeconds = "lectureParagraphPauseSeconds"
        static let lectureWindowSeconds = "lectureWindowSeconds"
        static let lectureLanguage = "lectureLanguage"
        static let lectureEngine = "lectureEngine"
    }

    private let defaults: UserDefaults
    /// `L-020`: the only path allowed to touch Login Items — a real
    /// `SystemLoginItemRegistry` in production, a fake under
    /// `ProcessRuntime.isRunningTests` or an injected test double.
    private let loginItemRegistry: any LoginItemRegistering
    /// Suppresses `launchAtLogin`'s `didSet` side effect while this type is
    /// merely mirroring a status the system already reports — at init, after
    /// a register/unregister attempt (success or failure), and when Settings
    /// re-opens and picks up an out-of-band system change.
    private var isApplyingSystemLoginItemStatus = false

    /// Global shortcut; default ⌥Space.
    @Published public var hotkey: HotkeyShortcut { didSet { persistHotkey() } }
    /// Default `toggle`.
    @Published public var recordingMode: RecordingMode { didSet { persist() } }
    /// `0...60` minutes of idle time before the model is released. Default
    /// `0` = keep it warm (`L-010`): a fixed idle timer made every later
    /// dictation pay a reload, so the model is now given back on system
    /// memory pressure instead. Non-zero is an explicit user choice.
    @Published public var modelUnloadMinutes: Int { didSet { persist() } }
    /// Default `true`.
    @Published public var historyEnabled: Bool {
        didSet {
            persist()
            historyEnabledMirror.value = historyEnabled
        }
    }
    /// Default `true`.
    @Published public var autoInsertEnabled: Bool { didSet { persist() } }
    /// Default `true`.
    @Published public var autoCorrectSafeTypos: Bool { didSet { persist() } }
    /// Default `auto`.
    @Published public var languageMode: TranscriptionLanguage { didSet { persist() } }
    /// `L-020`: source of truth is `SMAppService.mainApp.status`, not this
    /// property's own storage — it is never read back from `UserDefaults`.
    /// Setting it from user interaction (`didSet` below) asks the system to
    /// register/unregister; setting it from `syncLaunchAtLoginFromSystem()`
    /// only mirrors what the system already reports and must not re-trigger
    /// that request, which is what `isApplyingSystemLoginItemStatus` guards.
    @Published public var launchAtLogin: Bool {
        didSet {
            guard !isApplyingSystemLoginItemStatus, launchAtLogin != oldValue else { return }
            requestLoginItemChange(enable: launchAtLogin)
        }
    }
    /// Default `true`. When disabled, the app stays available from the menu
    /// bar but is absent from the Dock and app switcher.
    @Published public var showInDock: Bool { didSet { persist() } }

    /// Пауза, с которой в учебном режиме начинается новый абзац. От 1 до 10
    /// секунд, по умолчанию 2 — у разных говорящих разный темп, поэтому это
    /// настройка, а не константа.
    /// Движок распознавания лекции. `nil` — следовать за языком: на
    /// китайском система вчетверо быстрее и вдвое точнее, на русском Whisper
    /// точнее в разы. Замеры — в `docs/status.md`.
    @Published public var lectureEngine: LectureEngine? { didSet { persist() } }

    /// Язык лекции. Отдельно от языка диктовки: диктуют на одном языке,
    /// а лекции слушают на другом.
    ///
    /// По умолчанию задан явно, а не «автоматически». Ошибка определения на
    /// окне в несколько секунд стоит дорого: модель не отказывается
    /// распознавать, а передаёт услышанное словами назначенного языка, и
    /// китайская речь выходит набором русских слов.
    @Published public var lectureLanguage: TranscriptionLanguage { didSet { persist() } }

    /// Через сколько секунд речи расшифровка лекции пополняется на экране.
    ///
    /// Размен без правильного ответа: короче — текст появляется чаще, но
    /// модель видит меньше контекста и чаще ошибается, а постоянная накладная
    /// в полсекунды платится за каждое окно. Длиннее — точнее и экономнее,
    /// но ждать дольше.
    @Published public var lectureWindowSeconds: Double {
        didSet {
            let clamped = LectureRecorder.clampWindow(lectureWindowSeconds)
            guard clamped == lectureWindowSeconds else {
                lectureWindowSeconds = clamped
                return
            }
            persist()
        }
    }

    @Published public var lectureParagraphPauseSeconds: Double {
        didSet {
            let clamped = LectureParagraphBuilder.clampPause(lectureParagraphPauseSeconds)
            guard clamped == lectureParagraphPauseSeconds else {
                lectureParagraphPauseSeconds = clamped
                return
            }
            persist()
        }
    }
    /// Default `.github` (`AT-093`, `L-010`) — the project's own release is
    /// the only source reachable from mainland China. Applies to the *next* model
    /// download (and any tokenizer/config re-fetch); never re-downloads an
    /// already-verified local model.
    @Published public var modelDownloadSource: ModelDownloadSource { didSet { persist() } }

    /// v1 ships exactly one model (`INV-004`); not user-editable.
    public let modelID: String = ModelCatalog.modelID

    /// Convenience read path for the endpoint matching the current
    /// `modelDownloadSource` (`AT-093`).
    public var modelDownloadEndpoint: String { modelDownloadSource.endpoint }

    /// Thread-safe mirror of `historyEnabled`, kept in sync via `didSet`
    /// above. `HistoryStore` is a plain `actor` (not `@MainActor`), so its
    /// `historyEnabled: @Sendable () -> Bool` gate can't read the
    /// `@MainActor`-isolated `@Published` property directly (`L-008`) —
    /// this lock-protected box is the live, cross-isolation-safe read path
    /// `App.swift` hands it instead of a value captured once at launch.
    private let historyEnabledMirror = LockedBool(true)

    /// `@Sendable`, callable from any isolation domain (e.g. `HistoryStore`'s
    /// actor) — always reflects the *current* `historyEnabled` (`L-008`).
    public nonisolated var isHistoryEnabledNow: @Sendable () -> Bool {
        let mirror = historyEnabledMirror
        return { mirror.value }
    }

    public init(
        defaults: UserDefaults = .standard,
        loginItemRegistry: any LoginItemRegistering = ProcessRuntime.isRunningTests
            ? NullLoginItemRegistry() : SystemLoginItemRegistry()
    ) {
        self.defaults = defaults
        self.loginItemRegistry = loginItemRegistry
        self.hotkey = Self.loadHotkey(defaults) ?? .default
        self.recordingMode = RecordingMode(rawValue: defaults.string(forKey: Keys.recordingMode) ?? "") ?? .toggle
        // `L-010`: keep the model resident by default. Unloading it after an
        // idle timeout made every later dictation pay a reload (and, on the
        // first load after an app update, the multi-minute Core ML compile),
        // which reads as "the app is stuck". Users who want the ~600 MB back
        // can still set a timeout in Settings.
        self.modelUnloadMinutes = defaults.object(forKey: Keys.modelUnloadMinutes) as? Int ?? 0
        self.historyEnabled = defaults.object(forKey: Keys.historyEnabled) as? Bool ?? true
        self.autoInsertEnabled = defaults.object(forKey: Keys.autoInsertEnabled) as? Bool ?? true
        self.autoCorrectSafeTypos = defaults.object(forKey: Keys.autoCorrectSafeTypos) as? Bool ?? true
        self.languageMode = TranscriptionLanguage(rawValue: defaults.string(forKey: Keys.languageMode) ?? "") ?? .auto
        // `L-020`: never read from `UserDefaults` — a clean machine has no
        // registration, so the system status (`.notRegistered`) already
        // gives the documented "выключено" default without a stored flag
        // that could drift from it.
        self.launchAtLogin = Self.isEnabled(loginItemRegistry.status)
        self.showInDock = defaults.object(forKey: Keys.showInDock) as? Bool ?? true
        self.lectureEngine = (defaults.string(forKey: Keys.lectureEngine)).flatMap(LectureEngine.init(rawValue:))
        self.lectureLanguage = TranscriptionLanguage(
            rawValue: defaults.string(forKey: Keys.lectureLanguage) ?? ""
        ) ?? .zh
        self.lectureWindowSeconds = LectureRecorder.clampWindow(
            defaults.object(forKey: Keys.lectureWindowSeconds) as? Double
                ?? LectureRecorder.defaultWindowSeconds
        )
        self.lectureParagraphPauseSeconds = LectureParagraphBuilder.clampPause(
            defaults.object(forKey: Keys.lectureParagraphPauseSeconds) as? Double
                ?? LectureParagraphBuilder.defaultPauseSeconds
        )
        self.modelDownloadSource =
            ModelDownloadSource(rawValue: defaults.string(forKey: Keys.modelDownloadSource) ?? "") ?? .github
        // `historyEnabled`'s own `didSet` above doesn't fire for this
        // initializer assignment, so the mirror needs an explicit initial
        // sync to match the value just loaded from `UserDefaults`.
        historyEnabledMirror.value = self.historyEnabled
    }

    private func persist() {
        defaults.set(recordingMode.rawValue, forKey: Keys.recordingMode)
        defaults.set(modelUnloadMinutes, forKey: Keys.modelUnloadMinutes)
        defaults.set(historyEnabled, forKey: Keys.historyEnabled)
        defaults.set(autoInsertEnabled, forKey: Keys.autoInsertEnabled)
        defaults.set(autoCorrectSafeTypos, forKey: Keys.autoCorrectSafeTypos)
        defaults.set(languageMode.rawValue, forKey: Keys.languageMode)
        defaults.set(showInDock, forKey: Keys.showInDock)
        defaults.set(modelDownloadSource.rawValue, forKey: Keys.modelDownloadSource)
        defaults.set(lectureLanguage.rawValue, forKey: Keys.lectureLanguage)
        if let lectureEngine {
            defaults.set(lectureEngine.rawValue, forKey: Keys.lectureEngine)
        } else {
            defaults.removeObject(forKey: Keys.lectureEngine)
        }
        defaults.set(lectureParagraphPauseSeconds, forKey: Keys.lectureParagraphPauseSeconds)
        defaults.set(lectureWindowSeconds, forKey: Keys.lectureWindowSeconds)
    }

    private func persistHotkey() {
        guard let encoded = try? JSONEncoder().encode(hotkey) else { return }
        defaults.set(encoded, forKey: Keys.hotkey)
    }

    private static func loadHotkey(_ defaults: UserDefaults) -> HotkeyShortcut? {
        guard let data = defaults.data(forKey: Keys.hotkey) else { return nil }
        return try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
    }

    // MARK: - Launch at login (L-020)

    /// Called from `launchAtLogin`'s `didSet` when the user actually flips
    /// the switch (never for a mere system-status refresh). The blocking
    /// `SMAppService` call runs off the main actor (`INV-009`), and either
    /// way it finishes, the published value is resynced from whatever the
    /// system reports afterwards — on success that just confirms the
    /// requested state; on failure or a mismatched result it snaps the
    /// switch back to reality within the same interaction instead of
    /// leaving it wherever the user left it (`L-020`).
    private func requestLoginItemChange(enable: Bool) {
        let registry = loginItemRegistry
        loginItemRequestTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                if enable {
                    try registry.register()
                } else {
                    try registry.unregister()
                }
            } catch {
                await DiagnosticLog.shared.log(
                    "settings.launchAtLogin.failed",
                    detail: "enable=\(enable) error=\(String(describing: error))"
                )
            }
            await self?.syncLaunchAtLoginFromSystem(status: registry.status)
        }
    }

    /// The in-flight request started by the most recent `launchAtLogin`
    /// toggle, kept only so `waitForLoginItemRequestForTesting()` has
    /// something to await — production code never reads it back.
    private var loginItemRequestTask: Task<Void, Never>?

    /// Test-only: awaits the register/unregister request in flight from the
    /// most recent `launchAtLogin` toggle, so tests don't need to poll for
    /// the detached system call and its resync to finish. No-op if nothing
    /// is in flight.
    func waitForLoginItemRequestForTesting() async {
        await loginItemRequestTask?.value
    }

    /// Re-reads the system's actual status into `launchAtLogin` without
    /// re-triggering `requestLoginItemChange(enable:)` — the single path used
    /// both to correct after a register/unregister attempt above and to pick
    /// up an out-of-band change (`refreshLaunchAtLoginFromSystem()`).
    private func syncLaunchAtLoginFromSystem(status: SMAppService.Status? = nil) {
        let resolved = status ?? loginItemRegistry.status
        isApplyingSystemLoginItemStatus = true
        launchAtLogin = Self.isEnabled(resolved)
        isApplyingSystemLoginItemStatus = false
    }

    /// `L-020`: the system is the single source of truth for this switch's
    /// position. `SettingsView` calls this whenever its "Основное" tab
    /// becomes visible so a change made outside the app (System Settings →
    /// Login Items) is reflected without a restart.
    public func refreshLaunchAtLoginFromSystem() {
        syncLaunchAtLoginFromSystem()
    }

    private static func isEnabled(_ status: SMAppService.Status) -> Bool {
        status == .enabled
    }
}

/// Minimal lock-protected `Bool` box, `@unchecked Sendable` by construction
/// (every access goes through `NSLock`). Used solely to give
/// `historyEnabled` a live read path safe to call off `MainActor`.
nonisolated private final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool

    init(_ initialValue: Bool) {
        storage = initialValue
    }

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storage = newValue
        }
    }
}
