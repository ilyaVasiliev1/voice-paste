import AppKit
import XCTest
@testable import VoicePaste

final class VoicePasteTests: XCTestCase {
    func testTestTargetRuns() {
        XCTAssertTrue(true)
    }
}

/// Guards the headless unit gate (`VPGATE-001`). The app is its own XCTest host;
/// `AppDelegate.applicationWillFinishLaunching` runs before any test executes and,
/// under the test runtime, forces the non-activating `.prohibited` policy so
/// `xcodebuild test` never foregrounds a Dock icon.
///
/// The assertion drives the launch hook directly rather than reading the global
/// `NSApp.activationPolicy()` the suite happens to be in — other tests
/// (`AppStateRoutingTests`) deliberately toggle that shared policy, so reading it
/// would make this test depend on run order. Arranging a visible policy and then
/// invoking the exact hook the app uses proves the guard deterministically.
final class HeadlessTestHostTests: XCTestCase {
    @MainActor
    func testDelegateForcesProhibitedPolicyUnderTestRuntime() {
        XCTAssertTrue(ProcessRuntime.isRunningTests, "the suite must run under the recognised test runtime")

        NSApplication.shared.setActivationPolicy(.regular)
        AppDelegate().applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification)
        )

        XCTAssertEqual(
            NSApplication.shared.activationPolicy(),
            .prohibited,
            "applicationWillFinishLaunching must force .prohibited under the test runtime"
        )
    }
}

/// `VP-BUG-001`: the single-instance decision, proven on the pure
/// `SingleInstanceGuard.decide` so it needs no second real process. The guard
/// defers to an already-running instance of the same bundle id and otherwise
/// proceeds; a decision it gets wrong is either a duplicate app or a launch that
/// never starts.
final class SingleInstanceGuardTests: XCTestCase {
    private func instance(_ bundleID: String?, _ pid: pid_t) -> SingleInstanceGuard.RunningInstance {
        SingleInstanceGuard.RunningInstance(bundleIdentifier: bundleID, processIdentifier: pid)
    }

    func testDefersToExistingInstance() {
        let running = [
            instance("app.voicepaste", 100),   // an older instance already running
            instance("app.voicepaste", 640),   // this process
            instance("com.apple.finder", 42),  // unrelated app, must be ignored
        ]
        XCTAssertEqual(
            SingleInstanceGuard.decide(running: running, bundleIdentifier: "app.voicepaste", currentPID: 640),
            .deferToExisting(pid: 100)
        )
    }

    func testProceedsWhenSoleInstance() {
        let running = [
            instance("app.voicepaste", 640),   // only this process owns the bundle id
            instance("com.apple.finder", 42),
        ]
        XCTAssertEqual(
            SingleInstanceGuard.decide(running: running, bundleIdentifier: "app.voicepaste", currentPID: 640),
            .proceed
        )
    }

    func testIgnoresOtherBundleIdentifiers() {
        let running = [instance("com.other.app", 100), instance(nil, 7)]
        XCTAssertEqual(
            SingleInstanceGuard.decide(running: running, bundleIdentifier: "app.voicepaste", currentPID: 640),
            .proceed
        )
    }
}
