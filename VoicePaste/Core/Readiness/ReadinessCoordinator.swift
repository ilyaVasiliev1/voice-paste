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
        /// macOS has shown (or is about to show) its native consent sheet.
        case requested
        /// The permission is already granted; no UI action is needed.
        case alreadyAuthorized
        /// macOS remembers a denial. It will not show a second consent sheet;
        /// the only correct recovery is the Privacy & Security pane.
        case needsSystemSettings
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
        // presenting its consent sheet. Activate first, then wait one main
        // run-loop turn so the activation reaches WindowServer before asking.
        NSApp.activate(ignoringOtherApps: true)
        await Task.yield()

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
        return granted ? .alreadyAuthorized : .needsSystemSettings
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
