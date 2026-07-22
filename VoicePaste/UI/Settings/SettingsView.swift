import AppKit
import Foundation
import SwiftUI

/// `UI-005`. Sections map 1:1 to `ui-ux.md`; all controls bind to `DM-001`
/// via `AppSettings`, which persists to `UserDefaults` on every change.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsBody(appState: appState, settings: appState.settings)
    }
}

private enum SettingsTabItem: Hashable {
    case general, dictation, text, model, history
}

private struct SettingsBody: View {
    let appState: AppState
    @ObservedObject var settings: AppSettings
    @State private var vocabulary: [VocabularyEntry] = []
    @State private var showingClearHistoryConfirmation = false
    @State private var showingDeleteModelConfirmation = false
    @State private var newVocabularySpokenForm = ""
    @State private var newVocabularyReplacement = ""
    @State private var selectedTab: SettingsTabItem = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            generalSection
                .tag(SettingsTabItem.general)
                .tabItem { Label("settings.section.general", systemImage: "gearshape") }
            dictationSection
                .tag(SettingsTabItem.dictation)
                .tabItem { Label("settings.section.dictation", systemImage: "mic") }
            textSection
                .tag(SettingsTabItem.text)
                .tabItem { Label("settings.section.text", systemImage: "textformat") }
            modelSection
                .tag(SettingsTabItem.model)
                .tabItem { Label("settings.section.model", systemImage: "cpu") }
            historySection
                .tag(SettingsTabItem.history)
                .tabItem { Label("settings.section.history", systemImage: "clock") }
        }
        // Five labelled native tabs need a little more horizontal room in
        // Russian. Keeping the window wide enough avoids the opaque overflow
        // chevron that previously hid permissions and the dictionary.
        .frame(width: 720, height: 460)
        .task {
            await loadVocabulary()
            applyRequestedTab()
        }
        // `UI-003` "Выбрать микрофон": if Settings was already open when the
        // HUD button was clicked, `.task` above won't re-run — this covers
        // that case (the window is brought back to front by
        // `AppState.openSettingsToPermissions()` regardless).
        .onChange(of: appState.requestedSettingsTab) { _, _ in applyRequestedTab() }
        .onChange(of: settings.recordingMode) { _, _ in appState.settingsDidChange() }
        .onChange(of: settings.hotkey) { _, _ in appState.settingsDidChange() }
    }

    private func applyRequestedTab() {
        guard let requested = appState.requestedSettingsTab else { return }
        switch requested {
        // Permissions live on the visible "Основное" page. It keeps the
        // native settings toolbar at six items, without macOS's overflow
        // chevron hiding an important page.
        case .permissions: selectedTab = .general
        }
        appState.requestedSettingsTab = nil
    }

    private var generalSection: some View {
        Form {
            Section {
                Toggle("settings.general.launchAtLogin", isOn: $settings.launchAtLogin)
                Toggle("settings.general.showInDock", isOn: $settings.showInDock)
                    .onChange(of: settings.showInDock) { _, _ in appState.applyDockVisibility() }
            }
            permissionsControls
        }
        .formStyle(.grouped)
    }

    private var dictationSection: some View {
        Form {
            Section {
                HotkeyRecorderView(shortcut: $settings.hotkey)
            } header: {
                Text("settings.dictation.hotkey")
            }
            Picker("settings.dictation.mode", selection: $settings.recordingMode) {
                Text("settings.dictation.mode.toggle").tag(RecordingMode.toggle)
                Text("settings.dictation.mode.hold").tag(RecordingMode.hold)
            }
            Picker("settings.dictation.language", selection: $settings.languageMode) {
                Text("settings.language.auto").tag(TranscriptionLanguage.auto)
                Text("settings.language.ru").tag(TranscriptionLanguage.ru)
                Text("settings.language.en").tag(TranscriptionLanguage.en)
            }
        }
        .formStyle(.grouped)
    }

    private var textSection: some View {
        Form {
            Section("Текст") {
                Toggle("settings.text.autoCorrect", isOn: $settings.autoCorrectSafeTypos)
                Text("settings.text.autoCorrectExplanation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("settings.text.autoInsert", isOn: $settings.autoInsertEnabled)
            }
            vocabularyRows
        }
        .formStyle(.grouped)
    }

    private var modelSection: some View {
        Form {
            LabeledContent("settings.model.name", value: settings.modelID)
            LabeledContent("settings.model.size", value: ByteCountFormatter.string(
                fromByteCount: ModelCatalog.approximateSizeBytes,
                countStyle: .file
            ))
            LabeledContent("settings.model.status", value: modelStatusDescription)
            Picker("settings.model.downloadSource", selection: $settings.modelDownloadSource) {
                Text("settings.model.downloadSource.github").tag(ModelDownloadSource.github)
                Text("settings.model.downloadSource.mirror").tag(ModelDownloadSource.mirror)
                Text("settings.model.downloadSource.official").tag(ModelDownloadSource.official)
            }
            Text("settings.model.downloadSource.explanation")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("settings.model.loadOrRetry") {
                Task { _ = try? await appState.modelManager.ensureLoaded() }
            }
            Stepper(value: $settings.modelUnloadMinutes, in: 0...60) {
                LabeledContent("settings.model.unloadAfter", value: unloadMinutesDescription)
            }
            Button("settings.model.unloadNow") {
                appState.modelManager.unloadNow()
            }
            Text("settings.model.unloadNow.explanation")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(role: .destructive) {
                showingDeleteModelConfirmation = true
            } label: {
                Text("settings.model.delete")
            }
            .disabled(!isModelPresentOnDisk)
            .confirmationDialog(
                "settings.model.deleteConfirmTitle",
                isPresented: $showingDeleteModelConfirmation
            ) {
                Button("settings.model.deleteConfirmAction", role: .destructive) {
                    Task {
                        await appState.modelManager.deleteModel()
                        appState.refreshReadiness()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// `AT-094`: the delete button is only actionable once a model actually
    /// exists to delete — either resident in memory (`.ready`) or verified on
    /// disk but idle (`.unloaded`). Any other state (`.notPrepared`,
    /// `.downloading`, `.verifying`, `.failed`) has no `Models` directory
    /// contents worth confirming a deletion for.
    private var isModelPresentOnDisk: Bool {
        switch appState.modelManager.state {
        case .ready, .unloaded, .preparing: return true
        case .notPrepared, .downloading, .verifying, .failed: return false
        }
    }

    private var historySection: some View {
        Form {
            Toggle("settings.history.enabled", isOn: $settings.historyEnabled)
            Button(role: .destructive) {
                showingClearHistoryConfirmation = true
            } label: {
                Text("settings.history.clear")
            }
            .confirmationDialog(
                "settings.history.clearConfirmTitle",
                isPresented: $showingClearHistoryConfirmation
            ) {
                Button("settings.history.clearConfirmAction", role: .destructive) {
                    Task { try? await appState.historyStore.clearAll() }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var vocabularyRows: some View {
        Section {
            Grid(horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Произнесено")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Color.clear.frame(width: 16)
                    Text("Подставить")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Color.clear.frame(width: 52)
                }

                ForEach(vocabulary) { entry in
                    GridRow {
                        Text(entry.spokenForm)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(entry.replacement ?? entry.spokenForm)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        HStack(spacing: 8) {
                            Toggle("Включено", isOn: binding(for: entry))
                                .labelsHidden()
                                .toggleStyle(.switch)
                            Button(role: .destructive) {
                                Task { await deleteVocabularyEntry(entry) }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Удалить правило")
                        }
                    }
                }

                GridRow {
                    TextField("Произнесено", text: $newVocabularySpokenForm)
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    TextField("Подставить", text: $newVocabularyReplacement)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        Task { await addVocabularyEntry() }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(newVocabularySpokenForm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Добавить правило")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } header: {
            Text("Автозамены")
        } footer: {
            Text("Например: «кодекс» → «Codex». Автозамена применяется после распознавания текста.")
        }
    }

    private var permissionsControls: some View {
        Section("settings.section.permissions") {
            LabeledContent("settings.permissions.microphone", value: microphoneStatusDescription)
            if appState.readiness.microphoneAuthorization != .authorized {
                Button("settings.permissions.openSystemSettings") {
                    openSystemSettings(pane: "Privacy_Microphone")
                }
            }
            LabeledContent("settings.permissions.accessibility", value: accessibilityStatusDescription)
            if !appState.readiness.isAccessibilityTrusted {
                Button("settings.permissions.openSystemSettings") {
                    openSystemSettings(pane: "Privacy_Accessibility")
                }
            }
        }
        .task { appState.refreshReadiness() }
    }

    private var modelStatusDescription: String {
        switch appState.modelManager.state {
        case .ready, .unloaded: return NSLocalizedString("model.status.ready", comment: "")
        // On-disk model being brought into memory — not a download.
        case .preparing: return NSLocalizedString("model.status.preparing", comment: "")
        case .downloading: return NSLocalizedString("model.status.downloading", comment: "")
        case .verifying: return NSLocalizedString("model.status.verifying", comment: "")
        case .notPrepared: return NSLocalizedString("model.status.notPrepared", comment: "")
        case .failed: return NSLocalizedString("model.status.failed", comment: "")
        }
    }

    private var unloadMinutesDescription: String {
        settings.modelUnloadMinutes == 0
            ? NSLocalizedString("settings.model.unloadAfter.keepWarm", comment: "")
            : String(format: NSLocalizedString("settings.model.unloadAfter.minutes", comment: ""), settings.modelUnloadMinutes)
    }

    private var microphoneStatusDescription: String {
        appState.readiness.microphoneAuthorization == .authorized
            ? NSLocalizedString("permissions.status.granted", comment: "")
            : NSLocalizedString("permissions.status.notGranted", comment: "")
    }

    private var accessibilityStatusDescription: String {
        appState.readiness.isAccessibilityTrusted
            ? NSLocalizedString("permissions.status.granted", comment: "")
            : NSLocalizedString("permissions.status.notGranted", comment: "")
    }

    private func binding(for entry: VocabularyEntry) -> Binding<Bool> {
        Binding(
            get: { entry.isEnabled },
            set: { newValue in
                Task {
                    var updated = entry
                    updated.isEnabled = newValue
                    try? await appState.historyStore.upsertVocabulary(updated)
                    await loadVocabulary()
                }
            }
        )
    }

    private func addVocabularyEntry() async {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let entry = VocabularyEntry(
            id: UUID(),
            spokenForm: newVocabularySpokenForm,
            replacement: newVocabularyReplacement.isEmpty ? nil : newVocabularyReplacement,
            isEnabled: true,
            createdAt: now,
            updatedAt: now
        )
        try? await appState.historyStore.upsertVocabulary(entry)
        newVocabularySpokenForm = ""
        newVocabularyReplacement = ""
        await loadVocabulary()
    }

    private func deleteVocabularyEntry(_ entry: VocabularyEntry) async {
        try? await appState.historyStore.deleteVocabulary(id: entry.id)
        await loadVocabulary()
    }

    private func loadVocabulary() async {
        vocabulary = (try? await appState.historyStore.fetchVocabulary()) ?? []
    }

    private func openSystemSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
