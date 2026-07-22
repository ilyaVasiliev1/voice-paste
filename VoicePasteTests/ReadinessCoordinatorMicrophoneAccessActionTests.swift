import AVFoundation
import XCTest
@testable import VoicePaste

/// `AT-092`'s deterministic half: the pure status→action mapping behind
/// `ReadinessCoordinator.requestMicrophoneAccess()`. This does not touch a
/// real microphone, TCC, or system consent sheet — it directly exercises
/// `ReadinessCoordinator.microphoneAccessAction(for:)`, which is exactly the
/// function `requestMicrophoneAccess()` feeds the re-read
/// `AVAuthorizationStatus` through after a request completes (see the
/// doc-comment on that function). The real consent sheet appearing and the
/// app showing up in System Settings → «Микрофон» remain `живой smoke` +
/// `user-confirmed` per `spec/_tests.md`'s proof-mode matrix — not testable
/// headlessly.
@MainActor
final class ReadinessCoordinatorMicrophoneAccessActionTests: XCTestCase {

    func test_accessibilityPromptGate_coalescesOverlappingRequests_withoutCachingPermission() {
        let gate = AccessibilityPromptGate()

        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin(), "A second tap must not create another system prompt")
        gate.finish()
        XCTAssertTrue(gate.begin(), "Finishing only releases the in-flight lock; TCC is still re-read live")
    }

    func test_authorized_mapsTo_alreadyAuthorized() {
        let action = ReadinessCoordinator.microphoneAccessAction(for: .authorized)

        XCTAssertEqual(action, .alreadyAuthorized)
    }

    func test_denied_mapsTo_needsSystemSettings() {
        let action = ReadinessCoordinator.microphoneAccessAction(for: .denied)

        XCTAssertEqual(action, .needsSystemSettings)
    }

    func test_restricted_mapsTo_needsSystemSettings() {
        let action = ReadinessCoordinator.microphoneAccessAction(for: .restricted)

        XCTAssertEqual(action, .needsSystemSettings)
    }

    /// The regression this guards: a silently-skipped consent sheet leaves
    /// the status at `.notDetermined`, and `requestMicrophoneAccess()`'s
    /// completion handler alone reports `granted == false` — indistinguishable
    /// from a real denial if the caller trusted that bool. Routing
    /// `.notDetermined` to `.needsSystemSettings` would send the person to an
    /// empty "Микрофон" list in System Settings (`AT-092`'s documented dead
    /// end), instead of letting them retry from a state macOS can still
    /// present a prompt for. The explicit `!=` assertion is the load-bearing
    /// check here, not just equality to `.notPresented`.
    func test_notDetermined_mapsTo_notPresented_neverNeedsSystemSettings() {
        let action = ReadinessCoordinator.microphoneAccessAction(for: .notDetermined)

        XCTAssertEqual(action, .notPresented)
        XCTAssertNotEqual(
            action,
            .needsSystemSettings,
            "notDetermined must never route to System Settings — AT-092 empty-list regression"
        )
    }
}
