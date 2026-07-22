import AppKit
import AVFoundation
import ApplicationServices
import Combine
import Foundation

/// One live source of truth for the current process's Universal Access grant.
/// `AXIsProcessTrusted()` is deprecated; using the option-based API with no
/// prompt lets every consumer observe the same current TCC decision. The
/// consent sheet itself is requested only by `requestAccessibilityTrust()`.
public enum AccessibilityTrust {
    public static var isGranted: Bool {
        AXIsProcessTrustedWithOptions(nil)
    }
}

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
    /// Keeps the system Universal Access prompt single-flight. This is
    /// published so onboarding can avoid exposing its manual Settings
    /// fallback while macOS is still attaching the original prompt.
    @Published public private(set) var isAccessibilityTrustRequestInFlight = false

    private let modelManager: ModelManager
    private var modelStateCancellable: AnyCancellable?
    private let accessibilityPromptGate = AccessibilityPromptGate()

    public init(modelManager: ModelManager) {
        self.modelManager = modelManager
        self.microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
        self.isAccessibilityTrusted = AccessibilityTrust.isGranted
        refresh()
        // Model discovery starts on a utility executor. Reflect its eventual
        // `.unloaded` result in readiness as soon as it arrives, without
        // making launch wait for a recursive walk of the Core ML bundle.
        // `$state` publishes after the new value is available; `dropFirst`
        // skips the current synchronous snapshot already handled above.
        self.modelStateCancellable = modelManager.$state
            .dropFirst()
            .sink { [weak self] _ in self?.refresh() }
    }

    /// Recomputes `state` from current system status. Call after returning
    /// from System Settings, after a permission prompt resolves, and after
    /// model state changes.
    public func refresh() {
        microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
        isAccessibilityTrusted = AccessibilityTrust.isGranted

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

        await preparePrivacyPromptPresentation()

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

    /// Brings the window the person is currently using to the front before a
    /// TCC request. SwiftUI's `Window(id:)` is not guaranteed to expose that
    /// id as an `NSWindow.identifier`, so looking it up by a hard-coded
    /// identifier can silently fail and leave the privacy sheet behind the
    /// main window. The key window is the correct source of truth here; the
    /// visible/main fallbacks make the request equally reliable from a
    /// menu-bar-only launch. The short sleep yields to WindowServer — it is
    /// asynchronous and cannot block the UI or the permission flow.
    private func preparePrivacyPromptPresentation() async {
        NSApp.activate(ignoringOtherApps: true)
        let presentingWindow = NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey })
            ?? NSApp.windows.first(where: \.isVisible)
        presentingWindow?.makeKeyAndOrderFront(nil)
        presentingWindow?.orderFrontRegardless()
        await waitUntilActive(timeout: .seconds(1))
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    /// Prompts the Accessibility trust dialog (`EC-002`, `AT-003`).
    ///
    /// Just like microphone TCC, the request must come from an active
    /// application. A menu-bar utility can otherwise be technically
    /// inactive even though its onboarding panel is visible; macOS then
    /// routes the user to Settings without attaching the chosen grant to
    /// this process. Activating first makes this a normal app permission
    /// request — no relaunch or manual cache workaround is involved.
    public func requestAccessibilityTrust() {
        guard accessibilityPromptGate.begin() else {
            Task { await DiagnosticLog.shared.log("permission.accessibility.requestCoalesced") }
            return
        }
        isAccessibilityTrustRequestInFlight = true
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.accessibilityPromptGate.finish()
                self.isAccessibilityTrustRequestInFlight = false
            }
            await self.preparePrivacyPromptPresentation()

            // Another return path may have refreshed the state while the
            // app was being activated. Never ask macOS again if the grant is
            // already real; refresh keeps every published value consistent.
            guard !AccessibilityTrust.isGranted else {
                self.refresh()
                return
            }

            // "AXTrustedCheckOptionPrompt" is the stable, documented value
            // of `kAXTrustedCheckOptionPrompt`; the prompt is asynchronous.
            let options: [String: Bool] = ["AXTrustedCheckOptionPrompt": true]
            await DiagnosticLog.shared.log("permission.accessibility.requestStart")
            let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
            await DiagnosticLog.shared.log(
                "permission.accessibility.requestResult",
                detail: trusted ? "granted" : "pending"
            )
            self.refresh()
        }
    }
}

/// A tiny main-actor gate around the one system dialog that must never be
/// presented twice. It is independent from the permission value itself:
/// finishing a request does not cache denial or grant, so `refresh()` always
/// continues to read the real current TCC state.
@MainActor
final class AccessibilityPromptGate {
    private var isInFlight = false

    func begin() -> Bool {
        guard !isInFlight else { return false }
        isInFlight = true
        return true
    }

    func finish() {
        isInFlight = false
    }
}
