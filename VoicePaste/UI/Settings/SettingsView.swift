import AppKit
import Foundation
import SwiftUI

/// `UI-settings.tabs`. Sections map 1:1 to `ui-ux.md`; all controls bind to
/// via `AppSettings`, which persists to `UserDefaults` on every
/// change — except `launchAtLogin`, whose source of truth is
/// `SMAppService.mainApp.status`, not `UserDefaults`.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    var initialTab: SettingsTabItem = .general

    var body: some View {
        SettingsBody(appState: appState, settings: appState.settings, initialTab: initialTab)
    }
}

enum SettingsTabItem: Hashable {
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
    @State private var selectedTab: SettingsTabItem
    @State private var actionFailure: String?

    init(appState: AppState, settings: AppSettings, initialTab: SettingsTabItem) {
        self.appState = appState
        self.settings = settings
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("main.settings").font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 12).padding(.bottom, 20)
                settingsTab(.general, title: "settings.section.general", icon: "slider.horizontal.3")
                settingsTab(.dictation, title: "settings.section.dictation", icon: "waveform")
                settingsTab(.text, title: "settings.section.text", icon: "text.alignleft")
                settingsTab(.model, title: "settings.section.model", icon: "cpu")
                settingsTab(.history, title: "settings.section.history", icon: "clock")
                Spacer()
                VStack(alignment: .leading, spacing: 4) {
                    Text("VoicePaste \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")")
                    Text("Сборка \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")")
                    if let source = Bundle.main.object(forInfoDictionaryKey: "VoicePasteBuildFingerprint") as? String {
                        Text(source).textSelection(.enabled)
                    }
                }
                .font(.system(size: 10)).foregroundStyle(.secondary).padding(12)
            }
            .padding(12).padding(.top, 12).frame(width: 180)
            .background(WorkspacePalette.sidebar)
            Rectangle().fill(WorkspacePalette.line).frame(width: 1)
            Group {
                switch selectedTab {
                case .general: generalSection
                case .dictation: dictationSection
                case .text: textSection
                case .model: modelSection
                case .history: historySection
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, idealWidth: 720, minHeight: 460, idealHeight: 520)
        .task {
            await loadVocabulary()
            applyRequestedTab()
            // the system is the source of truth for this switch —
            // pick up a change made outside the app (System Settings →
            // Login Items) every time this window becomes visible again.
            settings.refreshLaunchAtLoginFromSystem()
        }
        // "Выбрать микрофон": if Settings was already open when the
        // HUD button was clicked, `.task` above won't re-run — this covers
        // that case (the window is brought back to front by
        // `AppState.openSettingsToPermissions()` regardless).
        .onChange(of: appState.requestedSettingsTab) { _, _ in applyRequestedTab() }
        .onChange(of: settings.recordingMode) { _, _ in appState.settingsDidChange() }
        .onChange(of: settings.hotkey) { _, _ in appState.settingsDidChange() }
    }

    private func settingsTab(_ tab: SettingsTabItem, title: LocalizedStringKey, icon: String) -> some View {
        Button { selectedTab = tab } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(WorkspaceRowStyle(selected: selectedTab == tab))
        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
    }

    private func applyRequestedTab() {
        guard let requested = appState.requestedSettingsTab else { return }
        switch requested {
        case .permissions: selectedTab = .general
        }
        appState.requestedSettingsTab = nil
    }

    private static func seconds(_ value: Double, fractionDigits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(fractionDigits))) + " с"
    }

    private var generalSection: some View {
        Form {
            Section {
                // this binding's getter reflects the system's own
                // `SMAppService.mainApp.status`, not a stored preference —
                // flipping it asks the system to register/unregister and the
                // switch snaps back to reality if that request fails.
                Toggle("settings.general.launchAtLogin", isOn: $settings.launchAtLogin)
                Toggle("settings.general.showInDock", isOn: $settings.showInDock)
                    .onChange(of: settings.showInDock) { _, _ in appState.applyDockVisibility() }
            }
            Section("settings.lecture.section") {
                // Порог паузы для абзацев лекции: у разных говорящих разный
                // темп, поэтому это настройка, а не константа.
                LabeledContent("settings.lecture.pause") {
                    HStack {
                        Slider(
                            value: $settings.lectureParagraphPauseSeconds,
                            in: LectureParagraphBuilder.pauseRange,
                            step: 0.5
                        )
                        Text(Self.seconds(settings.lectureParagraphPauseSeconds, fractionDigits: 1))
                            .font(.system(.body, design: .monospaced))
                            .frame(width: DesignTokens.sliderValueWidth, alignment: .trailing)
                    }
                }
                Text("settings.lecture.pauseDescription")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("settings.lecture.window") {
                    HStack {
                        Slider(
                            value: $settings.lectureWindowSeconds,
                            in: LectureRecorder.windowRange,
                            step: 1
                        )
                        Text(Self.seconds(settings.lectureWindowSeconds, fractionDigits: 0))
                            .font(.system(.body, design: .monospaced))
                            .frame(width: DesignTokens.sliderValueWidth, alignment: .trailing)
                    }
                }
                Text("settings.lecture.windowDescription")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Text("settings.dictation.mode.holdOrLatch").tag(RecordingMode.holdOrLatch)
            }
            if settings.recordingMode == .holdOrLatch {
                Text("settings.dictation.mode.holdOrLatch.explanation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker("settings.dictation.language", selection: $settings.languageMode) {
                Text("settings.language.auto").tag(TranscriptionLanguage.auto)
                Text("settings.language.ru").tag(TranscriptionLanguage.ru)
                Text("settings.language.en").tag(TranscriptionLanguage.en)
                Text("settings.language.zh").tag(TranscriptionLanguage.zh)
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
            if let actionFailure {
                Text(actionFailure).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }

    private var modelSection: some View {
        Form {
            LabeledContent("settings.model.name", value: NSLocalizedString("settings.model.displayName", comment: ""))
            LabeledContent(
                "settings.model.size",
                value: ByteCountFormatter.string(
                    fromByteCount: ModelCatalog.approximateSizeBytes,
                    countStyle: .binary
                ))
            LabeledContent("settings.model.status") {
                ModelLifecycleView(showsSourcePicker: false)
            }
            ModelSourcePicker(settings: settings)
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
            .disabled(!appState.modelManager.state.isInstalled)
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
                    Task {
                        do {
                            try await appState.historyStore.clearAll()
                        } catch {
                            actionFailure = NSLocalizedString("settings.failure.clearHistory", comment: "")
                        }
                    }
                }
            }
            if let actionFailure {
                Text(actionFailure).font(.caption).foregroundStyle(.red)
            }
            EvaluationAudioSection(appState: appState, settings: settings)
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

                if vocabulary.isEmpty {
                    GridRow {
                        Text("settings.vocabulary.empty")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .gridCellColumns(4)
                    }
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
                        HStack(spacing: DesignTokens.Spacing.sm) {
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
                            .accessibilityLabel(Text("Удалить правило"))
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
                    .accessibilityLabel(Text("Добавить правило"))
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

    private var unloadMinutesDescription: String {
        settings.modelUnloadMinutes == 0
            ? NSLocalizedString("settings.model.unloadAfter.keepWarm", comment: "")
            : String(
                format: NSLocalizedString("settings.model.unloadAfter.minutes", comment: ""),
                settings.modelUnloadMinutes)
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
                    do {
                        try await appState.historyStore.upsertVocabulary(updated)
                    } catch {
                        actionFailure = NSLocalizedString("settings.failure.vocabulary", comment: "")
                    }
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
        do {
            try await appState.historyStore.upsertVocabulary(entry)
        } catch {
            actionFailure = NSLocalizedString("settings.failure.vocabulary", comment: "")
        }
        newVocabularySpokenForm = ""
        newVocabularyReplacement = ""
        await loadVocabulary()
    }

    private func deleteVocabularyEntry(_ entry: VocabularyEntry) async {
        do {
            try await appState.historyStore.deleteVocabulary(id: entry.id)
        } catch {
            actionFailure = NSLocalizedString("settings.failure.vocabulary", comment: "")
        }
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
