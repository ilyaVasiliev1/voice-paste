import AppKit
import AVFoundation
import ApplicationServices
import Foundation

/// `API-local-readiness` (`L-001`, `US-001`). Recomputes `ReadinessState`
/// from live permission/model status; never starts a capture or inference
/// session by itself.
@MainActor
public final class ReadinessCoordinator: ObservableObject {
    @Published public private(set) var state: ReadinessState = .needsMicrophonePermission
    /// A snapshot of the live TCC values. Keeping them published makes a
    /// return from System Settings visibly update onboarding and Settings,
    /// even when the overall readiness state happens to stay the same.
    @Published public private(set) var microphoneAuthorization: AVAuthorizationStatus
    @Published public private(set) var isAccessibilityTrusted: Bool

    private let modelManager: ModelManager

    public init(modelManager: ModelManager) {
        self.modelManager = modelManager
        self.microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
        self.isAccessibilityTrusted = AXIsProcessTrusted()
        refresh()
    }

    /// Recomputes `state` from current system status. Call after returning
    /// from System Settings, after a permission prompt resolves, and after
    /// model state changes.
    public func refresh() {
        microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
        isAccessibilityTrusted = AXIsProcessTrusted()

        switch microphoneAuthorization {
        case .authorized:
            break
        case .notDetermined, .denied, .restricted:
            state = .needsMicrophonePermission
            return
        @unknown default:
            state = .needsMicrophonePermission
            return
        }

        guard isAccessibilityTrusted else {
            state = .needsAccessibilityPermission
            return
        }

        switch modelManager.state {
        case .ready:
            state = .ready
        case .unloaded:
            // `US-008`/`INV-011`/`L-010`: unloaded-after-idle-timeout still
            // means the model is verified on disk. `ensureLoaded()` reloads
            // it lazily on the next hotkey press, so the app stays `ready`
            // (not `needsModel`) — only a genuinely never-downloaded model
            // should block dictation.
            state = .ready
        case .downloading(let progress):
            state = .downloadingModel(progress: progress.fraction)
        case .verifying:
            state = .downloadingModel(progress: 1)
        case .notPrepared:
            state = .needsModel
        case .failed(let error):
            state = .error(error == .verificationFailed ? .modelMissing : .modelMissing)
        }
    }

    public enum MicrophoneAccessAction: Sendable, Equatable {
        /// The permission is already granted; no UI action is needed.
        case alreadyAuthorized
        /// macOS remembers a denial. It will not show a second consent sheet;
        /// the only correct recovery is the Privacy & Security pane.
        case needsSystemSettings
        /// The status is still `.notDetermined` after the request returned
        /// (macOS silently declined to present its consent sheet, typically
        /// because the process was not yet the active app). This is *not* a
        /// denial: System Settings has no entry for the app yet, so sending
        /// the person there would show an empty "Microphone" list
        /// (`AT-092`). The caller should explain and let the person retry.
        case notPresented
    }

    /// Maps a live `AVAuthorizationStatus` to the UI action to take. Pure and
    /// synchronous so it can be unit-tested without touching TCC or a real
    /// device (`AT-092`): `requestMicrophoneAccess()` re-reads the status
    /// after the request completes and feeds it through this function rather
    /// than trusting the `granted` bool the completion handler returns,
    /// because a silently-skipped consent sheet also reports `granted ==
    /// false` while leaving the status at `.notDetermined`.
    public static func microphoneAccessAction(for status: AVAuthorizationStatus) -> MicrophoneAccessAction {
        switch status {
        case .authorized:
            return .alreadyAuthorized
        case .denied, .restricted:
            return .needsSystemSettings
        case .notDetermined:
            return .notPresented
        @unknown default:
            return .needsSystemSettings
        }
    }

    /// Requests microphone access when macOS can still show its consent
    /// sheet. If the person previously denied access, tells the caller to
    /// open the exact System Settings pane instead of silently doing nothing.
    @discardableResult
    public func requestMicrophoneAccess() async -> MicrophoneAccessAction {
        refresh()
        Task {
            await DiagnosticLog.shared.log(
                "permission.microphone.statusBeforeRequest",
                detail: "rawValue=\(microphoneAuthorization.rawValue)"
            )
        }
        switch microphoneAuthorization {
        case .authorized:
            return .alreadyAuthorized
        case .denied, .restricted:
            return .needsSystemSettings
        case .notDetermined:
            break
        @unknown default:
            return .needsSystemSettings
        }

        // A menu-bar app can have an onboarding window on screen while the
        // process is technically inactive. TCC is allowed to immediately
        // reject a privacy request made from an inactive client instead of
        // presenting its consent sheet — a single `Task.yield()` is not
        // enough to guarantee the activation reached WindowServer before the
        // request fires. Activate, then actually wait for `NSApp.isActive`
        // (bounded, so a stuck activation cannot hang the flow forever).
        NSApp.activate(ignoringOtherApps: true)
        if let onboardingWindow = NSApp.windows.first(where: { $0.identifier?.rawValue == "onboarding" }) {
            onboardingWindow.makeKeyAndOrderFront(nil)
        }
        await waitUntilActive(timeout: .seconds(1))

        Task { await DiagnosticLog.shared.log("permission.microphone.requestStart") }
        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        Task { await DiagnosticLog.shared.log("permission.microphone.requestResult", detail: granted ? "granted" : "denied") }
        refresh()
        Task {
            await DiagnosticLog.shared.log(
                "permission.microphone.statusAfterRequest",
                detail: "rawValue=\(microphoneAuthorization.rawValue)"
            )
        }
        return Self.microphoneAccessAction(for: microphoneAuthorization)
    }

    /// Polls `NSApp.isActive` in short steps up to `timeout` instead of
    /// blocking indefinitely; activation is normally near-instant, but this
    /// must never hang the onboarding flow if it somehow does not land.
    private func waitUntilActive(timeout: Duration) async {
        let stepNanoseconds: UInt64 = 50_000_000 // 50 ms
        let deadline = ContinuousClock.now + timeout
        while !NSApp.isActive, ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: stepNanoseconds)
        }
    }

    /// Prompts the Accessibility trust dialog (`EC-002`, `AT-003`).
    public func requestAccessibilityTrust() {
        // "AXTrustedCheckOptionPrompt" is the stable, documented value of
        // `kAXTrustedCheckOptionPrompt`; used as a literal to avoid touching
        // the imported C global (not concurrency-safe to reference directly).
        let options: [String: Bool] = ["AXTrustedCheckOptionPrompt": true]
        Task { await DiagnosticLog.shared.log("permission.accessibility.requestStart") }
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        Task { await DiagnosticLog.shared.log("permission.accessibility.requestResult", detail: trusted ? "granted" : "pending") }
        refresh()
    }
}
