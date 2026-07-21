import XCTest
@testable import VoicePaste

/// Gate 1 unit tests for the pure `DictationStateMachine` (`L-002`, `L-003`,
/// `INV-005`). Covers `AT-003`'s logic half (toggle start/stop) and
/// `EC-003` (hotkey pressed again while `processing` is ignored, current job
/// preserved). No I/O, no audio, no hotkey manager involved.
@MainActor
final class DictationStateMachineTests: XCTestCase {

    // MARK: - Toggle mode (L-002, default)

    func test_toggle_firstPress_startsCapture() {
        var machine = DictationStateMachine(mode: .toggle)
        XCTAssertEqual(machine.phase, .idle)

        let effect = machine.handleHotkeyDown()

        XCTAssertEqual(effect, .startCapture)
        XCTAssertEqual(machine.phase, .recording)
    }

    func test_toggle_secondPress_stopsAndProcesses() {
        var machine = DictationStateMachine(mode: .toggle)
        _ = machine.handleHotkeyDown() // idle -> recording

        let effect = machine.handleHotkeyDown()

        XCTAssertEqual(effect, .stopCaptureAndProcess)
        XCTAssertEqual(machine.phase, .processing)
    }

    /// `EC-003`/`L-002`: "Повторные нажатия в processing игнорируются" — the
    /// job in flight must not be touched or restarted.
    func test_toggle_pressDuringProcessing_isIgnored_currentJobPreserved() {
        var machine = DictationStateMachine(mode: .toggle)
        _ = machine.handleHotkeyDown() // -> recording
        _ = machine.handleHotkeyDown() // -> processing
        XCTAssertEqual(machine.phase, .processing)

        // Several repeated presses while processing: all ignored, phase never moves.
        for _ in 0..<3 {
            let effect = machine.handleHotkeyDown()
            XCTAssertEqual(effect, .alreadyProcessing)
            XCTAssertEqual(machine.phase, .processing)
        }
    }

    /// Toggle mode never reacts to key-up (that's hold-mode only).
    func test_toggle_keyUp_isNoOp_inAnyPhase() {
        var machine = DictationStateMachine(mode: .toggle)
        XCTAssertEqual(machine.handleHotkeyUp(), .none)
        XCTAssertEqual(machine.phase, .idle)

        _ = machine.handleHotkeyDown() // -> recording
        XCTAssertEqual(machine.handleHotkeyUp(), .none)
        XCTAssertEqual(machine.phase, .recording)
    }

    func test_toggle_processingFinished_returnsToIdle() {
        var machine = DictationStateMachine(mode: .toggle)
        _ = machine.handleHotkeyDown() // -> recording
        _ = machine.handleHotkeyDown() // -> processing

        machine.handleProcessingFinished()

        XCTAssertEqual(machine.phase, .idle)
    }

    // MARK: - Hold mode (L-003)

    func test_hold_keyDown_startsCapture_keyUp_stopsAndProcesses() {
        var machine = DictationStateMachine(mode: .hold)

        XCTAssertEqual(machine.handleHotkeyDown(), .startCapture)
        XCTAssertEqual(machine.phase, .recording)

        XCTAssertEqual(machine.handleHotkeyUp(), .stopCaptureAndProcess)
        XCTAssertEqual(machine.phase, .processing)
    }

    /// Key-repeat while physically holding the key down must not restart or
    /// stop anything.
    func test_hold_keyRepeatWhileRecording_isNoOp() {
        var machine = DictationStateMachine(mode: .hold)
        _ = machine.handleHotkeyDown() // -> recording

        let effect = machine.handleHotkeyDown()

        XCTAssertEqual(effect, .none)
        XCTAssertEqual(machine.phase, .recording)
    }

    /// A stray key-up outside of `.recording` (e.g. after processing already
    /// started) must not fire a second stop/process.
    func test_hold_keyUp_outsideRecording_isNoOp() {
        var machine = DictationStateMachine(mode: .hold)
        XCTAssertEqual(machine.handleHotkeyUp(), .none) // idle
        XCTAssertEqual(machine.phase, .idle)

        _ = machine.handleHotkeyDown() // -> recording
        _ = machine.handleHotkeyUp() // -> processing
        XCTAssertEqual(machine.handleHotkeyUp(), .none) // already processing
        XCTAssertEqual(machine.phase, .processing)
    }

    /// `EC-003` in hold mode too: a key-down while processing is ignored.
    func test_hold_keyDownDuringProcessing_isIgnored() {
        var machine = DictationStateMachine(mode: .hold)
        _ = machine.handleHotkeyDown() // -> recording
        _ = machine.handleHotkeyUp() // -> processing

        XCTAssertEqual(machine.handleHotkeyDown(), .alreadyProcessing)
        XCTAssertEqual(machine.phase, .processing)
    }

    func test_hold_processingFinished_returnsToIdle_readyForNextSession() {
        var machine = DictationStateMachine(mode: .hold)
        _ = machine.handleHotkeyDown()
        _ = machine.handleHotkeyUp()

        machine.handleProcessingFinished()
        XCTAssertEqual(machine.phase, .idle)

        // A fresh key-down after finishing starts a brand new session.
        XCTAssertEqual(machine.handleHotkeyDown(), .startCapture)
        XCTAssertEqual(machine.phase, .recording)
    }

    // MARK: - Mode switching mid-flight (`AT-011`-adjacent logic)

    func test_changingModeProperty_appliesToSubsequentTransitions() {
        var machine = DictationStateMachine(mode: .toggle)
        _ = machine.handleHotkeyDown() // -> recording (toggle semantics)

        // Settings changed mid-session (mirrors `AppState.settingsDidChange`).
        machine.mode = .hold

        // Now behaves like hold: key-up stops it.
        XCTAssertEqual(machine.handleHotkeyUp(), .stopCaptureAndProcess)
        XCTAssertEqual(machine.phase, .processing)
    }

    // MARK: - UI-003: HUD mouse controls ("Готово"/"Отменить")

    /// The HUD button must finish a `.hold`-mode session too, unlike a mouse
    /// click routed through `handleHotkeyDown()` (which would be a no-op
    /// key-repeat in `.hold`).
    func test_finishFromUI_holdMode_whileRecording_stopsAndProcesses() {
        var machine = DictationStateMachine(mode: .hold)
        _ = machine.handleHotkeyDown() // -> recording

        XCTAssertEqual(machine.finishFromUI(), .stopCaptureAndProcess)
        XCTAssertEqual(machine.phase, .processing)
    }

    func test_finishFromUI_toggleMode_whileRecording_stopsAndProcesses() {
        var machine = DictationStateMachine(mode: .toggle)
        _ = machine.handleHotkeyDown() // -> recording

        XCTAssertEqual(machine.finishFromUI(), .stopCaptureAndProcess)
        XCTAssertEqual(machine.phase, .processing)
    }

    func test_finishFromUI_outsideRecording_isNoOp() {
        var machine = DictationStateMachine(mode: .toggle)
        XCTAssertEqual(machine.finishFromUI(), .none)
        XCTAssertEqual(machine.phase, .idle)

        _ = machine.handleHotkeyDown() // -> recording
        _ = machine.handleHotkeyDown() // -> processing
        XCTAssertEqual(machine.finishFromUI(), .none, "must not touch a job already processing")
        XCTAssertEqual(machine.phase, .processing)
    }

    func test_cancelFromUI_whileRecording_discardsAndReturnsToIdle() {
        var machine = DictationStateMachine(mode: .toggle)
        _ = machine.handleHotkeyDown() // -> recording

        XCTAssertEqual(machine.cancelFromUI(), .cancelCapture)
        XCTAssertEqual(machine.phase, .idle, "cancel skips .processing entirely")
    }

    func test_cancelFromUI_holdMode_whileRecording_discardsAndReturnsToIdle() {
        var machine = DictationStateMachine(mode: .hold)
        _ = machine.handleHotkeyDown() // -> recording

        XCTAssertEqual(machine.cancelFromUI(), .cancelCapture)
        XCTAssertEqual(machine.phase, .idle)
    }

    func test_cancelFromUI_outsideRecording_isNoOp() {
        var machine = DictationStateMachine(mode: .toggle)
        XCTAssertEqual(machine.cancelFromUI(), .none)
        XCTAssertEqual(machine.phase, .idle)

        _ = machine.handleHotkeyDown() // -> recording
        _ = machine.handleHotkeyDown() // -> processing
        XCTAssertEqual(machine.cancelFromUI(), .none, "must not touch a job already processing")
        XCTAssertEqual(machine.phase, .processing)
    }

    /// After a cancel, a fresh hotkey press starts a brand new session
    /// (the machine truly returned to `.idle`, not some in-between state).
    func test_cancelFromUI_thenFreshHotkeyDown_startsNewSession() {
        var machine = DictationStateMachine(mode: .toggle)
        _ = machine.handleHotkeyDown() // -> recording
        _ = machine.cancelFromUI() // -> idle

        XCTAssertEqual(machine.handleHotkeyDown(), .startCapture)
        XCTAssertEqual(machine.phase, .recording)
    }
}
