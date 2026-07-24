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
