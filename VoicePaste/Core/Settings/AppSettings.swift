import Foundation

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
        static let launchAtLogin = "launchAtLogin"
        static let showInDock = "showInDock"
    }

    private let defaults: UserDefaults

    /// Global shortcut; default ⌥Space.
    @Published public var hotkey: HotkeyShortcut { didSet { persistHotkey() } }
    /// Default `toggle`.
    @Published public var recordingMode: RecordingMode { didSet { persist() } }
    /// `1...60`; `0` keeps the model warm. Default `10`.
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
    /// Default `false` (`UI-005`: "запуск при входе в macOS (выключен по умолчанию)").
    @Published public var launchAtLogin: Bool { didSet { persist() } }
    /// Default `true`. When disabled, the app stays available from the menu
    /// bar but is absent from the Dock and app switcher.
    @Published public var showInDock: Bool { didSet { persist() } }

    /// v1 ships exactly one model (`INV-004`); not user-editable.
    public let modelID: String = ModelCatalog.modelID

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

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hotkey = Self.loadHotkey(defaults) ?? .default
        self.recordingMode = RecordingMode(rawValue: defaults.string(forKey: Keys.recordingMode) ?? "") ?? .toggle
        self.modelUnloadMinutes = defaults.object(forKey: Keys.modelUnloadMinutes) as? Int ?? 10
        self.historyEnabled = defaults.object(forKey: Keys.historyEnabled) as? Bool ?? true
        self.autoInsertEnabled = defaults.object(forKey: Keys.autoInsertEnabled) as? Bool ?? true
        self.autoCorrectSafeTypos = defaults.object(forKey: Keys.autoCorrectSafeTypos) as? Bool ?? true
        self.languageMode = TranscriptionLanguage(rawValue: defaults.string(forKey: Keys.languageMode) ?? "") ?? .auto
        self.launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        self.showInDock = defaults.object(forKey: Keys.showInDock) as? Bool ?? true
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
        defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
        defaults.set(showInDock, forKey: Keys.showInDock)
    }

    private func persistHotkey() {
        guard let encoded = try? JSONEncoder().encode(hotkey) else { return }
        defaults.set(encoded, forKey: Keys.hotkey)
    }

    private static func loadHotkey(_ defaults: UserDefaults) -> HotkeyShortcut? {
        guard let data = defaults.data(forKey: Keys.hotkey) else { return nil }
        return try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
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
