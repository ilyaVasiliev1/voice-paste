import AppKit
import SwiftUI

/// Owns the single non-activating `NSPanel` used to render `HUDState`
/// (`UI-003`, `INV-006`, `DESIGN.md`). Always bottom-center of the active
/// screen, never becomes key, never steals focus from the app the user is
/// dictating into.
@MainActor
public final class HUDWindowController {
    private let stateHolder = HUDStateHolder()
    private let panel: NSPanel
    /// Keeping a concrete hosting view, rather than an autosizing hosting
    /// controller, removes the last layout negotiation between SwiftUI and
    /// the transparent AppKit panel. The host is always 360 × 144; only the
    /// inner material surface changes state.
    private let hostingView: NSHostingView<HUDContentView>
    private var dismissTask: Task<Void, Never>?
    private var dismissDeadline: Date?
    private var pausedDismissalRemaining: TimeInterval?

    /// Re-entrancy guard: `present(_:)` is called ~5-10x/sec while recording
    /// (elapsed ticker + level meter, `L-004`). Without this guard, a
    /// re-entrant call arriving while a previous `present` is still on the
    /// stack (e.g. from a nested run-loop turn triggered by SwiftUI's own
    /// state-driven layout) could re-enter AppKit's layout machinery and
    /// trigger `_NSDetectedLayoutRecursion` (`UI-003`, `INV-006`).
    private var isPresenting = false

    public init() {
        let hostingView = NSHostingView(rootView: HUDContentView(stateHolder: stateHolder))
        hostingView.frame = NSRect(x: 0, y: 0, width: 360, height: 144)
        hostingView.autoresizingMask = [.width, .height]
        let panel = NSPanel(
            // This frame never changes while the HUD is visible. Its
            // transparent margin hosts the animated inner material surface.
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 144),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The SwiftUI material surface owns its visual shadow. A window-level
        // shadow around a transparent 360 × 144 host can make AppKit defer
        // compositing it during a fast state update.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false
        self.panel = panel
        self.hostingView = hostingView

    }

    /// Shows (or updates) the HUD with a new state, positioned bottom-center
    /// of the active screen, and schedules the auto-dismiss timers from
    /// `HUDState.autoDismissDelay` (`inserted` 1.5 s, `error` 4 s).
    ///
    /// Content updates (`stateHolder.state`, driving the SwiftUI redraw) and
    /// repositioning (an AppKit frame computation) are deliberately kept
    /// separate: the former runs on every call (including the frequent
    /// recording ticks), the latter only when the HUD is being newly shown
    /// or its `kind` changes, per `UI-003`/`INV-006`.
    public func present(_ state: HUDState) {
        guard !isPresenting else { return }
        isPresenting = true
        defer { isPresenting = false }

        guard state != .hidden else {
            cancelDismissTimer()
            panel.orderOut(nil)
            stateHolder.state = .hidden
            return
        }

        let previousKind = stateHolder.state.kind
        let needsReposition = !panel.isVisible
        let kindChanged = previousKind != state.kind
        stateHolder.state = state

        if needsReposition {
            reposition()
        }

        // Do not synchronously flush AppKit layout/compositing here. A drop
        // changes from the 144 pt target to a compact status in the same
        // event turn; forced layout and display made that transition visibly
        // hitch. SwiftUI schedules the new content for the next frame, while
        // this controller only brings a newly-visible panel to front.
        if needsReposition {
            hostingView.needsLayout = true
            panel.orderFrontRegardless()
            panel.order(.above, relativeTo: 0)
        }
        if needsReposition || kindChanged {
            Task {
                await DiagnosticLog.shared.log(
                    "hud.present",
                    detail: "kind=\(String(describing: state.kind)) visible=\(panel.isVisible)"
                )
            }
        }

        if kindChanged || needsReposition {
            configureDismissTimer(for: state)
        }
    }

    public func hide() {
        present(.hidden)
    }

    /// Wires the HUD's mouse-button actions (`UI-003`) to whatever
    /// `AppState`/`DictationStateMachine` calls make sense for each — this
    /// controller only owns presentation, never dictation logic itself.
    public func configureActions(
        onFinish: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onSelectMicrophone: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        onImportFileDropped: @escaping (URL) -> Void,
        onChooseImportFile: @escaping () -> Void,
        onOpenHistoryRecord: @escaping (UUID) -> Void,
        onSwitchToImport: @escaping () -> Void,
        onResumeRecording: @escaping () -> Void,
        onImportResultCopied: @escaping () -> Void,
        onImportResultOpened: @escaping () -> Void,
        onCancelPausedDictation: @escaping () -> Void
    ) {
        stateHolder.actions = HUDActions(
            onFinish: onFinish,
            onCancel: onCancel,
            onRetry: onRetry,
            onSelectMicrophone: onSelectMicrophone,
            onDismiss: onDismiss,
            onImportFileDropped: onImportFileDropped,
            onChooseImportFile: onChooseImportFile,
            onOpenHistoryRecord: onOpenHistoryRecord,
            onSwitchToImport: onSwitchToImport,
            onResumeRecording: onResumeRecording,
            onInteractionChanged: { [weak self] isHovering in
                self?.setDismissTimerPaused(isHovering)
            },
            onImportResultCopied: onImportResultCopied,
            onImportResultOpened: onImportResultOpened,
            onCancelPausedDictation: onCancelPausedDictation
        )
    }

    private func configureDismissTimer(for state: HUDState) {
        cancelDismissTimer()
        guard let delay = state.autoDismissDelay else { return }
        scheduleDismiss(after: delay)
    }

    private func scheduleDismiss(after delay: TimeInterval, startingProgress: CGFloat = 1) {
        guard delay > 0 else {
            present(.hidden)
            return
        }
        dismissDeadline = Date().addingTimeInterval(delay)
        stateHolder.dismissProgress = startingProgress
        dismissTask = Task { [weak self] in
            let startedAt = Date()
            while let self, !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(startedAt)
                let remainingFraction = max(0, 1 - elapsed / delay)
                self.stateHolder.dismissProgress = startingProgress * remainingFraction
                guard remainingFraction > 0 else {
                    self.present(.hidden)
                    return
                }
                try? await Task.sleep(nanoseconds: 33_333_333)
            }
        }
    }

    private func cancelDismissTimer() {
        dismissTask?.cancel()
        dismissTask = nil
        dismissDeadline = nil
        pausedDismissalRemaining = nil
        stateHolder.dismissProgress = 0
    }

    /// The import result stays available while a pointer is over one of its
    /// surface. Leaving the surface resumes the remaining timeout instead of
    /// restarting it, so a user cannot accidentally lose a nearly-expired
    /// result while aiming for Copy/Open.
    private func setDismissTimerPaused(_ isHovering: Bool) {
        guard case .importFinished = stateHolder.state else { return }
        if isHovering {
            guard let dismissDeadline else { return }
            pausedDismissalRemaining = max(0, dismissDeadline.timeIntervalSinceNow)
            dismissTask?.cancel()
            dismissTask = nil
            self.dismissDeadline = nil
        } else if let remaining = pausedDismissalRemaining {
            let currentProgress = stateHolder.dismissProgress
            pausedDismissalRemaining = nil
            scheduleDismiss(after: remaining, startingProgress: currentProgress)
        }
    }

    /// The host panel is one fixed transparent frame. Changing a HUD state
    /// never resizes or moves an NSWindow — SwiftUI animates one inner shape.
    private func reposition() {
        panel.setFrameOrigin(panelOrigin(for: panel.frame.size))
    }

    private func panelOrigin(for panelSize: NSSize) -> NSPoint {
        let screen = activeScreen()
        // Raised well clear of the Dock/screen edge (`UI-003`'s "не у самого
        // низа" — the HUD must stay comfortably readable above the Dock
        // while recording/importing/showing a result), not flush against it.
        // TOK-hud.baseline — единая нижняя линия для всех состояний.
        let bottomInset: CGFloat = 28
        let originX = screen.visibleFrame.midX - panelSize.width / 2
        let originY = screen.visibleFrame.minY + bottomInset
        return NSPoint(x: originX, y: originY)
    }

    /// Main screen is intentional. A HUD that follows the pointer can appear
    /// on a different monitor from the actively used document and look as if
    /// it did not open at all. The main display is predictable and matches
    /// where the menu-bar app opens its primary window.
    private func activeScreen() -> NSScreen {
        return NSScreen.main
            ?? NSScreen.screens[0]
    }
}
