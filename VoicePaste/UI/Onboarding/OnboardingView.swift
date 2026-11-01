import AppKit
import SwiftUI

/// sequential native onboarding. Every step explains why the
/// permission is needed, offers a System Settings deep link, and can be
/// skipped for now — actual readiness (`ReadinessCoordinator`) is computed
/// independently from live system status, not from wizard progress.
struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Step
    @State private var accessibilityPollTask: Task<Void, Never>?
    /// set when `requestMicrophoneAccess()` returns
    /// `.notPresented` — macOS silently skipped its consent sheet. Cleared on
    /// every fresh attempt and whenever the step changes.
    @State private var didFailToPresentConsentSheet = false
    /// Universal Access has only one initial action. After asking macOS once,
    /// System Settings becomes an explicit fallback instead of a competing
    /// second button that can open a duplicate window while the system sheet
    /// is still resolving.
    @State private var didRequestAccessibility = false
    /// The manual Settings fallback intentionally appears after macOS has
    /// had a moment to attach its own prompt. Without this, a fast second
    /// click could open Settings on top of the first system request.
    @State private var isAccessibilityFallbackAvailable = false
    @State private var accessibilityFallbackTask: Task<Void, Never>?
    @State private var isOpeningAccessibilitySettings = false

    enum Step: Int, CaseIterable {
        case purpose, microphone, accessibility, model
    }

    init(initialStep: Step = .purpose) {
        _step = State(initialValue: initialStep)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform").font(.system(size: 20, weight: .semibold))
                    Text("VoicePaste").font(.system(size: 16, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Step.allCases, id: \.rawValue) { item in
                        HStack(spacing: 10) {
                            Text("\(item.rawValue + 1)")
                                .font(.system(size: 10, weight: .medium))
                                .frame(width: 18, height: 18)
                                .overlay { Circle().strokeBorder(Color.primary.opacity(item == step ? 0.7 : 0.2)) }
                            Text(stepName(item)).font(.system(size: 12, weight: item == step ? .semibold : .regular))
                        }
                        .foregroundStyle(item.rawValue <= step.rawValue ? Color.primary : Color.secondary)
                        .accessibilityAddTraits(item == step ? .isSelected : [])
                    }
                }
                Spacer()
                Text("На вашем Mac.\nБез аккаунта и подписки.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
            }
            .padding(24).frame(width: 190, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(WorkspacePalette.sidebar)
            Rectangle().fill(WorkspacePalette.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 20) {
                Text(String(format: NSLocalizedString("onboarding.step", comment: ""),
                    step.rawValue + 1, Step.allCases.count))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                ScrollView {
                    stepContent.id(step).transition(.opacity)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                Spacer(minLength: 0)
                if step == .model, let missing = missingPermissionStep {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(NSLocalizedString(appState.readiness.state.statusLocalizationKey, comment: ""))
                        Spacer()
                        Button("onboarding.fixPermission") { step = missing }
                            .buttonStyle(WorkspaceActionStyle())
                    }.font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    if step != .purpose {
                        Button("onboarding.back") { goBack() }.buttonStyle(WorkspaceActionStyle())
                    }
                    Spacer()
                    Button(step == .model ? "onboarding.finish" : "onboarding.next") { goNext() }
                        .buttonStyle(WorkspaceActionStyle(primary: true))
                        .disabled(step == .model && !canFinishModelStep)
                }
            }
            .padding(28).frame(maxWidth: .infinity)
            .buttonStyle(WorkspaceActionStyle())
            .background(WorkspacePalette.document)
        }
        .frame(width: 720, height: 480)
        .animation(DesignTokens.Motion.respecting(DesignTokens.Motion.fade, reduceMotion: reduceMotion), value: step)
        .task { appState.refreshReadiness() }
        // System Settings does not send VoicePaste a dedicated “privacy
        // value changed” notification. Re-check when it becomes active
        // again; the coordinator also polls while this step is visible, so
        // either return path updates the screen without a relaunch.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appState.refreshReadiness()
        }
        .onChange(of: step) { _, newStep in
            updateAccessibilityPolling(for: newStep)
            if newStep != .microphone {
                didFailToPresentConsentSheet = false
            }
            if newStep != .accessibility {
                didRequestAccessibility = false
                isAccessibilityFallbackAvailable = false
                isOpeningAccessibilitySettings = false
                accessibilityFallbackTask?.cancel()
                accessibilityFallbackTask = nil
            }
        }
        .onAppear {
            appState.setOnboardingVisible(true)
        }
        .onDisappear {
            stopAccessibilityPolling()
            accessibilityFallbackTask?.cancel()
            appState.setOnboardingVisible(false)
        }
    }

    private func stepName(_ step: Step) -> String {
        switch step {
        case .purpose: return "Начало"
        case .microphone: return "Микрофон"
        case .accessibility: return "Вставка текста"
        case .model: return "Модель"
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .purpose: purposeStep
        case .microphone: microphoneStep
        case .accessibility: accessibilityStep
        case .model: modelStep
        }
    }

    private var purposeStep: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Text("onboarding.purpose.title").font(.title2.bold())
            Text("onboarding.purpose.body")
        }
    }

    private var microphoneStep: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Text("onboarding.microphone.title").font(.title2.bold())
            Text("onboarding.microphone.body")
            if appState.readiness.microphoneAuthorization != .authorized {
                Button("onboarding.microphone.grant") {
                    didFailToPresentConsentSheet = false
                    Task {
                        let action = await appState.readiness.requestMicrophoneAccess()
                        // only a *real* denial sends the
                        // person to System Settings. `.notPresented` means
                        // macOS silently skipped its consent sheet — System
                        // Settings would show an empty "Microphone" list, so
                        // stay here and let them retry instead.
                        if action == .needsSystemSettings {
                            openSystemSettings(pane: "Privacy_Microphone")
                        } else if action == .notPresented {
                            didFailToPresentConsentSheet = true
                        }
                    }
                }
                // the manual System Settings link is only
                // safe to show for a *real* denial (`.denied`/`.restricted`).
                // At `.notDetermined` the app is not yet listed under
                // Privacy & Security → Microphone, so this button would open
                // an empty list — a dead end the spec forbids.
                if appState.readiness.microphoneAuthorization == .denied
                    || appState.readiness.microphoneAuthorization == .restricted {
                    Button("onboarding.openSystemSettings") { openSystemSettings(pane: "Privacy_Microphone") }
                }
            }
            if didFailToPresentConsentSheet {
                Text("onboarding.microphone.notPresented")
                    .foregroundStyle(.secondary)
            }
            Text(microphoneStatusKey)
                .foregroundStyle(.secondary)
        }
    }

    private var accessibilityStep: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Text("onboarding.accessibility.title").font(.title2.bold())
            Text("onboarding.accessibility.body")
            if !appState.readiness.isAccessibilityTrusted {
                if didRequestAccessibility {
                    Text("onboarding.accessibility.requested")
                        .foregroundStyle(.secondary)
                    if isAccessibilityFallbackAvailable,
                       !appState.readiness.isAccessibilityTrustRequestInFlight {
                        Button("onboarding.openSystemSettings") {
                            openAccessibilitySystemSettings()
                        }
                        .disabled(isOpeningAccessibilitySettings)
                    }
                } else {
                    Button("onboarding.accessibility.grant") {
                        didRequestAccessibility = true
                        isAccessibilityFallbackAvailable = false
                        appState.readiness.requestAccessibilityTrust()
                        scheduleAccessibilityFallback()
                    }
                    .disabled(appState.readiness.isAccessibilityTrustRequestInFlight)
                }
            }
            Text(appState.readiness.isAccessibilityTrusted ? "onboarding.status.granted" : "onboarding.status.pending")
                .foregroundStyle(.secondary)
        }
    }

    private var microphoneStatusKey: LocalizedStringKey {
        switch appState.readiness.microphoneAuthorization {
        case .authorized:
            return "onboarding.status.granted"
        case .denied, .restricted:
            return "onboarding.microphone.status.systemSettings"
        case .notDetermined:
            return "onboarding.status.pending"
        @unknown default:
            return "onboarding.status.pending"
        }
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Text("onboarding.model.title").font(.title2.bold())
            Text("onboarding.model.body")
            ModelLifecycleView()
        }
    }

    /// The wizard cannot be dismissed while the model is absent, failed, or
    /// still downloading. `.unloaded` means the verified files are installed
    /// locally but the engine is not resident, so it is a valid completed
    /// onboarding state just like `.ready`/`.preparing`.
    private var canFinishModelStep: Bool {
        appState.modelManager.state.isInstalled
    }

    private func goNext() {
        appState.refreshReadiness()
        if step == .model {
            finish()
            return
        }
        if let next = Step(rawValue: step.rawValue + 1) {
            step = next
        }
    }

    /// Шаг, на котором не хватает разрешения, — чтобы «Готово» не закрывало окно молча.
    private var missingPermissionStep: Step? {
        switch appState.readiness.state {
        case .needsMicrophonePermission: return .microphone
        case .needsAccessibilityPermission: return .accessibility
        default: return nil
        }
    }

    private func goBack() {
        if let previous = Step(rawValue: step.rawValue - 1) {
            step = previous
        }
    }

    /// `UI-002`/task 2: the last step's "Готово" must actually close the
    /// onboarding window — previously `Step(rawValue: 4)` was `nil` and
    /// `goNext()` silently did nothing. If readiness is now `.ready`, also
    /// bring up the single main window so the user lands
    /// somewhere useful instead of at an empty menu bar.
    private func finish() {
        dismissWindow(id: "onboarding")
        if appState.readiness.state == .ready {
            openWindow(id: "main")
        }
    }

    private func openSystemSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func scheduleAccessibilityFallback() {
        accessibilityFallbackTask?.cancel()
        accessibilityFallbackTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            isAccessibilityFallbackAvailable = true
        }
    }

    private func openAccessibilitySystemSettings() {
        guard !isOpeningAccessibilitySettings else { return }
        isOpeningAccessibilitySettings = true
        openSystemSettings(pane: "Privacy_Accessibility")
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            isOpeningAccessibilitySettings = false
        }
    }

    /// While the Accessibility step is visible, refresh the actual TCC
    /// status every ~1.5 s. This covers both returning to the app and the
    /// case where System Settings keeps the app inactive while the user
    /// flips the switch.
    private func updateAccessibilityPolling(for newStep: Step) {
        stopAccessibilityPolling()
        guard newStep == .accessibility else { return }
        accessibilityPollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                appState.refreshReadiness()
            }
        }
    }

    private func stopAccessibilityPolling() {
        accessibilityPollTask?.cancel()
        accessibilityPollTask = nil
    }
}
