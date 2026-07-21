import Foundation

/// `DM-001.recordingMode`.
public enum RecordingMode: String, Codable, CaseIterable, Sendable {
    case toggle
    case hold
}

public enum DictationPhase: Equatable, Sendable {
    case idle
    case recording
    case processing
}

/// Side effect the caller must perform in response to a hotkey/lifecycle
/// event. Kept as data (not a closure call) so the state machine itself
/// stays a pure, synchronous, easily unit-testable value type (`_tests.md`:
/// "Unit-тесты: state machine диктовки").
public enum DictationEffect: Equatable, Sendable {
    /// Start `AVAudioEngine` capture and show the HUD (`L-004`).
    case startCapture
    /// Stop capture and hand the buffer to the transcriber (`L-005`).
    case stopCaptureAndProcess
    /// `UI-003` HUD "Отменить" button: stop capture and discard the buffer
    /// entirely — no transcription, no history row.
    case cancelCapture
    /// `EC-003`: a hotkey press arrived while `processing`; ignore it and
    /// surface "Расшифровка уже идёт" without touching the current job.
    case alreadyProcessing
    case none
}

/// Pure toggle/hold dictation state machine (`L-002`, `L-003`, `INV-005`).
/// Contains no I/O; `DictationController` drives real audio/transcription
/// side effects from the `DictationEffect` values this type returns.
public struct DictationStateMachine: Equatable, Sendable {
    public private(set) var phase: DictationPhase = .idle
    public var mode: RecordingMode

    public init(mode: RecordingMode) {
        self.mode = mode
    }

    /// Toggle mode: fires once per hotkey press. Hold mode: fires on key-down.
    public mutating func handleHotkeyDown() -> DictationEffect {
        switch phase {
        case .idle:
            phase = .recording
            return .startCapture
        case .recording:
            switch mode {
            case .toggle:
                phase = .processing
                return .stopCaptureAndProcess
            case .hold:
                // Key-repeat while holding: no-op, still recording.
                return .none
            }
        case .processing:
            return .alreadyProcessing
        }
    }

    /// Hold mode only: fires on key-up. No-op in toggle mode/other phases.
    public mutating func handleHotkeyUp() -> DictationEffect {
        guard mode == .hold, phase == .recording else { return .none }
        phase = .processing
        return .stopCaptureAndProcess
    }

    /// Transcription (or the empty/too-short guard, `EC-005`) finished, success or failure.
    public mutating func handleProcessingFinished() {
        phase = .idle
    }

    /// `UI-003` HUD "Готово"/✓ button — mode-independent equivalent of the
    /// hotkey's stop trigger. Deliberately separate from
    /// `handleHotkeyDown()`: in `.hold` mode a second key-*down* while
    /// already `.recording` is a harmless key-repeat no-op (the session
    /// stops on key-*up* instead), but a mouse click has no "repeat" concept
    /// and must always finish the session it's shown on.
    public mutating func finishFromUI() -> DictationEffect {
        guard phase == .recording else { return .none }
        phase = .processing
        return .stopCaptureAndProcess
    }

    /// `UI-003` HUD "Отменить"/✕ button — discards the in-flight recording
    /// entirely and returns straight to `.idle`, skipping `.processing`
    /// (there is nothing to transcribe: the caller must drop the captured
    /// audio without handing it to the transcriber or saving history).
    public mutating func cancelFromUI() -> DictationEffect {
        guard phase == .recording else { return .none }
        phase = .idle
        return .cancelCapture
    }
}
