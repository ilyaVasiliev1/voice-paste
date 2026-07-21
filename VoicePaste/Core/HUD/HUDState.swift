import Foundation

/// The single recovery action an `.error` HUD state may offer
/// (`UI-003`/`DESIGN.md`: "красный статус + одно релевантное действие").
/// `nonisolated`: under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` every
/// declaration in this module — including a plain, non-actor `enum`'s cases —
/// defaults to `@MainActor` isolation unless stated otherwise. `HUDState
/// .error`'s default parameter value below (`action: HUDErrorAction = .none`)
/// is evaluated in a `nonisolated` context (an enum case's default
/// argument), so `.none` itself must be reachable without a main-actor hop.
public nonisolated enum HUDErrorAction: Equatable, Sendable {
    /// No recoverable action beyond the always-present "×" close.
    case none
    /// EC-005-style "couldn't hear you"/`alreadyProcessing`: start a brand
    /// new dictation session immediately.
    case retry
    /// `dictation.microphoneError`: the single relevant recovery is picking
    /// a working input device in Settings → Разрешения.
    case selectMicrophone
}

/// HUD content per `DESIGN.md` "Единая система HUD" (`UI-003`, `INV-006`).
public nonisolated enum HUDState: Equatable, Sendable {
    case hidden
    /// `DESIGN.md`: capsule 240–280 pt × 48 pt. No preview text and no
    /// second line — the hotkey hint lives in the menu/Settings and in this
    /// state's own accessibility label, not printed here.
    case recording(elapsed: TimeInterval, level: Float)
    case processing
    /// Auto-dismisses after 1.5 s.
    case inserted
    /// Shown when direct insertion was not possible (`INV-008`). Same
    /// 1.5 s auto-dismiss as `.inserted` — clipboard fallback is still a
    /// successful, momentary confirmation (`L-007`), not a state that
    /// should linger until the next HUD present.
    case copied
    /// `UI-003` HUD "Отменить" button: a brief confirmation that the
    /// in-flight dictation was discarded, not transcribed. Same 1.5 s
    /// auto-dismiss as `.inserted`/`.copied` — this is a successful, final
    /// outcome for the session, not an error.
    case cancelled
    /// Escape pauses the active capture: a compact strip says only "Отмена"
    /// and offers a non-textual return affordance to continue that same
    /// accumulated recording.
    case cancelledWithUndo
    /// Stays up to 4 s. `action` (`DESIGN.md`) surfaces at most one recovery
    /// button for the recoverable cases; everything else only gets the
    /// message and the close button — never more than one action, never a
    /// second line of detail ("не расползается в карточку").
    case error(message: String, action: HUDErrorAction = .none)
    /// `UI-006`/`UI-003`: a stable raised drop target, visible before a file
    /// is dragged. It keeps the same geometry while hovering so the panel
    /// never jumps under the pointer.
    case importIdle
    /// `DM-005` real progress (`ImportJob.progress`/`.state`) while a file
    /// decodes/transcribes, in the same container — no new card. Stays up
    /// until completion/failure.
    case importing
    /// The finished result: "Готово" plus `Копировать`/`Открыть в истории`.
    /// The full text is intentionally not rendered here (`DESIGN.md`) —
    /// `text` is carried only so `Копировать` has something to place on the
    /// pasteboard; `transcriptID` is what `Открыть в истории` selects once
    /// the main window is frontmost. Auto-dismisses after 4 s, same as
    /// `.error` — `Копировать`/`Открыть в истории` also remain reachable
    /// from `HistoryView` itself afterward, nothing is lost by the timeout.
    case importFinished(text: String, transcriptID: UUID)
    /// Short acknowledgement after the user opens a completed file result in
    /// the main VoicePaste window.
    case importOpened

    public var autoDismissDelay: TimeInterval? {
        switch self {
        case .inserted, .copied, .cancelled, .importOpened: return 1.5
        case .cancelledWithUndo: return 4.0
        case .error, .importFinished: return 4.0
        default: return nil
        }
    }

    /// Case identity ignoring associated values (elapsed/level change many
    /// times per second while `.recording` — `HUDWindowController` uses this
    /// to tell "same on-screen layout, new content" apart from "different
    /// layout, needs repositioning" without re-running AppKit layout on
    /// every tick).
    public enum Kind: Equatable, Sendable {
        case hidden, recording, processing, inserted, copied, cancelled, cancelledWithUndo, error
        case importIdle, importing, importFinished, importOpened
    }

    public var kind: Kind {
        switch self {
        case .hidden: return .hidden
        case .recording: return .recording
        case .processing: return .processing
        case .inserted: return .inserted
        case .copied: return .copied
        case .cancelled: return .cancelled
        case .cancelledWithUndo: return .cancelledWithUndo
        case .error: return .error
        case .importIdle: return .importIdle
        case .importing: return .importing
        case .importFinished: return .importFinished
        case .importOpened: return .importOpened
        }
    }
}
