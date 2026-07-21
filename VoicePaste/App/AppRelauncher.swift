import AppKit
import Foundation

/// `EC-002`/onboarding Accessibility step: `AXIsProcessTrusted()` can keep
/// returning a stale (pre-grant) value for the lifetime of the running
/// process on some macOS versions, even after the user flips the toggle in
/// System Settings and returns. There is no supported API to force a
/// re-read — the only reliable fix is to relaunch the process so trust is
/// evaluated fresh at startup.
@MainActor
public enum AppRelauncher {
    /// Launches a new instance of the app bundle via `/usr/bin/open`, then
    /// terminates the current process. `open` decouples the new instance's
    /// lifecycle from this one, so it survives `NSApp.terminate`.
    public static func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [bundlePath]
        Task { await DiagnosticLog.shared.log("app.relaunch.requested") }
        do {
            try process.run()
        } catch {
            Task { await DiagnosticLog.shared.log("app.relaunch.failed", detail: String(describing: error)) }
            return
        }
        NSApp.terminate(nil)
    }
}
