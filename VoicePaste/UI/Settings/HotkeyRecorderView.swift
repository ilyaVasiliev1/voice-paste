import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Native shortcut recorder for `UI-005` "Диктовка" section (`AT-011`).
///
/// Two explicit states, matching the fix brief:
/// - idle — shows the current combination plus a "Изменить" caption hint;
/// - recording — activated by click or Space/Return, shows "Нажмите
///   сочетание…" and a highlighted border while it is `firstResponder`.
///
/// Captures the raw virtual key code + modifier mask on the next key press
/// while recording — the same representation `HotkeyManager`'s
/// `CGEventTap` compares against, so what you record is exactly what
/// triggers globally. Esc cancels without changing `shortcut`; Delete/
/// Backspace resets to `HotkeyShortcut.default`. A combination without at
/// least one modifier is rejected (it would otherwise collide with normal
/// typing once registered as a *global* hotkey) and shows a brief inline
/// hint instead of being applied.
struct HotkeyRecorderView: View {
    @Binding var shortcut: HotkeyShortcut

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HotkeyRecorderCapsule(shortcut: $shortcut)
            Text("settings.hotkey.changeHint")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct HotkeyRecorderCapsule: NSViewRepresentable {
    @Binding var shortcut: HotkeyShortcut

    func makeNSView(context: Context) -> RecorderNSView {
        let view = RecorderNSView()
        view.onCapture = { newShortcut in shortcut = newShortcut }
        view.displayShortcut = shortcut
        return view
    }

    func updateNSView(_ nsView: RecorderNSView, context: Context) {
        nsView.displayShortcut = shortcut
    }
}

final class RecorderNSView: NSView {
    var onCapture: ((HotkeyShortcut) -> Void)?

    var displayShortcut: HotkeyShortcut = .default {
        didSet {
            guard !isRecording else { return }
            needsDisplay = true
        }
    }

    private var isRecording = false {
        didSet { needsDisplay = true }
    }

    /// Brief "нужен хотя бы один модификатор" hint shown in place of the
    /// placeholder before reverting, so the user can immediately retry
    /// without losing recording focus.
    private var showingModifierHint = false {
        didSet { needsDisplay = true }
    }
    private var hintResetWorkItem: DispatchWorkItem?

    private static let relevantFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    private static let fixedHeight: CGFloat = 24
    private static let minWidth: CGFloat = 148

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityLabel(NSLocalizedString("settings.hotkey.recorderAccessibilityLabel", comment: ""))
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.minWidth, height: Self.fixedHeight) }
    override var focusRingType: NSFocusRingType {
        get { .default }
        set { /* fixed to .default; system decides visibility */ }
    }

    override func drawFocusRingMask() {
        capsulePath.fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        beginRecording()
    }

    override func becomeFirstResponder() -> Bool {
        true
    }

    override func resignFirstResponder() -> Bool {
        cancelRecording()
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            // Keyboard-only activation (VoiceOver/Tab focus): Space/Return
            // arm recording, matching standard control conventions. Any
            // other key while merely focused (not yet recording) is a no-op
            // rather than an unexpected system beep.
            if event.keyCode == UInt16(kVK_Space) || event.keyCode == UInt16(kVK_Return) {
                beginRecording()
            }
            return
        }

        switch Int(event.keyCode) {
        case kVK_Escape:
            cancelRecording()
            return
        case kVK_Delete, kVK_ForwardDelete:
            isRecording = false
            showingModifierHint = false
            onCapture?(.default)
            return
        default:
            break
        }

        let flags = event.modifierFlags.intersection(Self.relevantFlags)
        guard !flags.isEmpty else {
            flashModifierHint()
            return
        }

        isRecording = false
        showingModifierHint = false
        onCapture?(HotkeyShortcut(keyCode: UInt32(event.keyCode), modifierFlags: flags.rawValue))
    }

    private func beginRecording() {
        hintResetWorkItem?.cancel()
        showingModifierHint = false
        isRecording = true
    }

    private func cancelRecording() {
        hintResetWorkItem?.cancel()
        isRecording = false
        showingModifierHint = false
    }

    private func flashModifierHint() {
        showingModifierHint = true
        let workItem = DispatchWorkItem { [weak self] in
            self?.showingModifierHint = false
        }
        hintResetWorkItem?.cancel()
        hintResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
    }

    private var capsulePath: NSBezierPath {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let isKey = window?.firstResponder === self

        let fillColor: NSColor
        if isRecording {
            fillColor = .controlAccentColor.withAlphaComponent(0.18)
        } else if isKey {
            fillColor = .controlAccentColor.withAlphaComponent(0.10)
        } else {
            fillColor = .controlColor
        }
        fillColor.setFill()
        capsulePath.fill()

        let stroke = capsulePath
        stroke.lineWidth = isRecording ? 1.5 : 1
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        stroke.stroke()

        let text = currentText
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: showingModifierHint ? NSColor.systemRed : NSColor.labelColor
        ]
        let size = text.size(withAttributes: attributes)
        let origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        text.draw(at: origin, withAttributes: attributes)
    }

    private var currentText: String {
        if showingModifierHint {
            return NSLocalizedString("settings.hotkey.needsModifier", comment: "")
        }
        if isRecording {
            return NSLocalizedString("settings.hotkey.recording", comment: "")
        }
        return displayShortcut.displayString
    }
}
