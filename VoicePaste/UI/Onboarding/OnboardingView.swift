import AppKit
import SwiftUI

/// `UI-002`: sequential native onboarding. Every step explains why the
/// permission is needed, offers a System Settings deep link, and can be
/// skipped for now — actual readiness (`ReadinessCoordinator`) is computed
/// independently from live system status, not from wizard progress.
struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @State private var step: Step = .purpose
    @State private var accessibilityPollTask: Task<Void, Never>?
    /// `AT-092`/`UI-002`: set when `requestMicrophoneAccess()` returns
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

    private enum Step: Int, CaseIterable {
        case purpose, microphone, accessibility, model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepContent
            Spacer()
            HStack {
                if step != .purpose {
                    Button("onboarding.back") { goBack() }
                }
                Spacer()
                Button(step == .model ? "onboarding.finish" : "onboarding.next") {
                    goNext()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 480, height: 360)
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
        VStack(alignment: .leading, spacing: 12) {
            Text("onboarding.purpose.title").font(.title2.bold())
            Text("onboarding.purpose.body")
        }
    }

    private var microphoneStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("onboarding.microphone.title").font(.title2.bold())
            Text("onboarding.microphone.body")
            if appState.readiness.microphoneAuthorization != .authorized {
                Button("onboarding.microphone.grant") {
                    didFailToPresentConsentSheet = false
                    Task {
                        let action = await appState.readiness.requestMicrophoneAccess()
                        // `AT-092`/`UI-002`: only a *real* denial sends the
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
                // `AT-092`/`UI-002`: the manual System Settings link is only
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
        VStack(alignment: .leading, spacing: 12) {
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
        VStack(alignment: .leading, spacing: 12) {
            Text("onboarding.model.title").font(.title2.bold())
            Text("onboarding.model.body")
            modelStateBody
        }
    }

    @ViewBuilder
    private var modelStateBody: some View {
        switch appState.modelManager.state {
        case .ready, .unloaded:
            // `.unloaded` here means "verified on disk, not resident in
            // memory" (`L-001`/`AT-004`) — onboarding should treat it as
            // done, not prompt a needless re-download.
            Label("onboarding.model.ready", systemImage: "checkmark.circle.fill")
        case .downloading(let progress):
            modelDownloadingBody(progress)
        case .verifying:
            ProgressView()
            Text("onboarding.model.verifying")
        case .failed:
            Text("onboarding.model.failed").foregroundStyle(.red)
            // `AT-096`/`UI-002`: the same source setting as Settings, so
            // switching here and retrying starts the next attempt from the
            // newly chosen source without leaving onboarding.
            ModelSourcePicker(settings: appState.settings)
            Button("onboarding.model.retry") {
                Task { _ = try? await appState.modelManager.ensureLoaded() }
            }
        case .notPrepared:
            // `AT-096`/`UI-002`: shown before the first download attempt too.
            ModelSourcePicker(settings: appState.settings)
            Button("onboarding.model.download") {
                Task { _ = try? await appState.modelManager.ensureLoaded() }
            }
        }
    }

    /// `AT-086`/`L-010`/`UI-002`: honest download progress — percent and
    /// "N из 626 МБ" read straight from `ModelDownloadProgress`'s byte
    /// counters, plus current speed and an ETA that only appears once the
    /// smoothed speed is a trustworthy signal (until then, "Считаем
    /// время…", mirroring `AT-062`'s import progress wording).
    private func modelDownloadingBody(_ progress: ModelDownloadProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: progress.fraction)
            HStack {
                Text(Self.byteCountFormatter.string(fromByteCount: progress.completedBytes)
                     + " " + String(format: NSLocalizedString("onboarding.model.ofTotal", comment: ""),
                                     Self.byteCountFormatter.string(fromByteCount: progress.totalBytes)))
                Spacer()
                Text(Self.percentFormatter.string(from: NSNumber(value: progress.fraction)) ?? "")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(speedAndETAText(progress))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func speedAndETAText(_ progress: ModelDownloadProgress) -> String {
        guard let speed = progress.speedBytesPerSecond, speed > 0 else {
            return NSLocalizedString("onboarding.model.calculatingTime", comment: "")
        }
        let speedText = String(
            format: NSLocalizedString("onboarding.model.speed", comment: ""),
            Self.byteCountFormatter.string(fromByteCount: Int64(speed))
        )
        guard let eta = progress.etaSeconds, eta.isFinite, eta >= 0 else {
            return speedText
        }
        let etaText = String(
            format: NSLocalizedString("onboarding.model.eta", comment: ""),
            Self.durationText(eta)
        )
        return speedText + " · " + etaText
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let value = Int(seconds.rounded())
        return value >= 60 ? "\(value / 60) мин" : "\(value) с"
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter
    }()

    private static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter
    }()

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

    private func goBack() {
        if let previous = Step(rawValue: step.rawValue - 1) {
            step = previous
        }
    }

    /// `UI-002`/task 2: the last step's "Готово" must actually close the
    /// onboarding window — previously `Step(rawValue: 4)` was `nil` and
    /// `goNext()` silently did nothing. If readiness is now `.ready`, also
    /// bring up the single main window (`UI-008`) so the user lands
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

/// `AT-096`/`UI-002`: the same download-source setting exposed on the
/// model step — not a separate piece of state. Mirrors `SettingsView`'s
/// `Picker`/tags so `settings.modelDownloadSource` (`AT-093`, `L-010`)
/// stays the single source of truth; `@ObservedObject` here (like
/// `SettingsBody`) is what makes the shared `AppSettings` instance drive
/// this control's live state.
private struct ModelSourcePicker: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("settings.model.downloadSource", selection: $settings.modelDownloadSource) {
                Text("settings.model.downloadSource.mirror").tag(ModelDownloadSource.mirror)
                Text("settings.model.downloadSource.official").tag(ModelDownloadSource.official)
            }
            Text("onboarding.model.sourceRecommendation")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
