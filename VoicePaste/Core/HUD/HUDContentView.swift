import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A single composited HUD surface. The NSPanel is deliberately fixed at the
/// largest required size; only this inner shape morphs. That avoids an AppKit
/// window resize racing SwiftUI layout during a state change.
struct HUDContentView: View {
    @ObservedObject var stateHolder: HUDStateHolder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // The drop target is intentionally an inner affordance, never a second
    // panel or a border around the whole HUD. It tells the user exactly
    // where to release a file without changing the persistent surface.
    @State private var isImportTargeted = false

    var body: some View {
        let state = stateHolder.state
        let layout = HUDLayout.forState(state)

        ZStack(alignment: .bottom) {
            if state != .hidden {
                RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
                    // A restrained dark scrim preserves the native material
                    // while separating the HUD from dark chat/editor windows.
                    .overlay {
                        RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous)
                            .fill(.black.opacity(0.20))
                            .allowsHitTesting(false)
                    }
                    .frame(width: layout.width, height: layout.height)
                    // The material and dark scrim already separate the HUD.
                    // An extra black drop shadow looked like a horizontal
                    // stripe under the panel on dark windows, so it is
                    // intentionally omitted.
                    .overlay {
                        content(for: state)
                            .frame(width: layout.width, height: layout.height)
                    }
                    .overlay(alignment: .bottom) {
                        autoDismissProgress(for: state, cornerRadius: layout.cornerRadius)
                    }
                    .onHover { stateHolder.actions.onInteractionChanged($0) }
            }
        }
        .frame(width: HUDLayout.hostWidth, height: HUDLayout.hostHeight, alignment: .bottom)
        .compositingGroup()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: layout)
    }

    @ViewBuilder
    private func content(for state: HUDState) -> some View {
        switch state {
        case .hidden:
            EmptyView()
        case let .recording(elapsed, level):
            recording(elapsed: elapsed, level: level)
        case .processing:
            compactStatus(textKey: "hud.processing")
        case .inserted:
            compactStatus(textKey: "hud.inserted")
        case .copied:
            compactStatus(textKey: "hud.copied")
        case .cancelled:
            compactStatus(textKey: "hud.cancelled")
        case .cancelledWithUndo:
            cancelledWithUndo
        case let .error(message, action):
            error(message: message, action: action)
        case .importIdle:
            importIdle
        case .importing:
            importing
        case let .importFinished(text, _):
            importFinished(text: text)
        case .importOpened:
            compactStatus(textKey: "hud.import.opened")
        }
    }

    private func recording(elapsed: TimeInterval, level: Float) -> some View {
        HStack(spacing: 7) {
            hudButton(
                symbol: "arrow.down.doc",
                labelKey: "hud.action.importFile",
                action: stateHolder.actions.onSwitchToImport
            )
            hudButton(symbol: "xmark", labelKey: "hud.action.cancel", action: stateHolder.actions.onCancel)
            Circle().fill(.red).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(elapsedString(elapsed))
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .frame(width: 38, alignment: .leading)
            LevelMeter(level: level).frame(width: 68, height: 16).accessibilityHidden(true)
            hudButton(symbol: "checkmark", labelKey: "hud.action.finish", tint: .accentColor, action: stateHolder.actions.onFinish)
        }
        // 28 pt buttons inside a 48 pt capsule leave 10 pt above and below;
        // matching the horizontal inset keeps the compact control balanced.
        .padding(HUDLayout.contentInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("hud.recording.accessibilityLabel"))
    }

    private func compactStatus(textKey: LocalizedStringKey) -> some View {
        Text(textKey)
            .font(.callout.weight(.medium))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .multilineTextAlignment(.center)
            .padding(HUDLayout.contentInset)
    }

    private var cancelledWithUndo: some View {
        HStack(spacing: 0) {
            hudButton(
                symbol: "xmark",
                labelKey: "hud.action.dismiss",
                action: stateHolder.actions.onCancelPausedDictation
            )
            Spacer(minLength: 0)
            Text("hud.cancelled.short").font(.callout.weight(.medium))
            Spacer(minLength: 0)
            hudButton(
                symbol: "arrow.uturn.backward",
                labelKey: "hud.action.resumeRecording",
                action: stateHolder.actions.onResumeRecording
            )
        }
        .padding(HUDLayout.contentInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func error(message: String, action: HUDErrorAction) -> some View {
        HStack(spacing: 8) {
            // Keep equally sized edge slots. The status therefore stays
            // optically centred in the same way as every text-only HUD
            // state, while an actionable error still exposes Retry/Close.
            // `Color.clear` is deliberate: it reserves the left control
            // space without introducing a decorative error icon.
            Group {
                switch action {
                case .none:
                    Color.clear
                case .retry:
                    hudButton(symbol: "arrow.clockwise", labelKey: "hud.action.retry", action: stateHolder.actions.onRetry)
                case .selectMicrophone:
                    hudButton(symbol: "mic.badge.xmark", labelKey: "hud.action.selectMicrophone", action: stateHolder.actions.onSelectMicrophone)
                }
            }
            .frame(width: HUDLayout.controlSize, height: HUDLayout.controlSize)
            Text(message)
                .font(.callout.weight(.medium))
                .foregroundStyle(.red)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
            hudButton(symbol: "xmark", labelKey: "hud.action.dismiss", action: stateHolder.actions.onDismiss)
        }
        .padding(HUDLayout.contentInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var importIdle: some View {
        VStack(spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.down.doc").foregroundStyle(.secondary)
                Text("hud.import.title").font(.callout.weight(.medium))
                Spacer()
                hudButton(symbol: "xmark", labelKey: "hud.action.dismiss", action: stateHolder.actions.onDismiss)
            }
            Button(action: stateHolder.actions.onChooseImportFile) {
                VStack(spacing: 5) {
                    Image(systemName: "waveform.badge.plus").font(.title3)
                    Text("hud.import.dropTargetHint").font(.caption.weight(.medium))
                    Text("hud.import.chooseHint").font(.caption2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isImportTargeted ? Color.accentColor : .secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                isImportTargeted ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isImportTargeted ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.22),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
                    .allowsHitTesting(false)
            }
            // The complete dashed rectangle is one native click target —
            // not merely its icon or explanatory text.
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(HUDLayout.contentInset)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isImportTargeted)
        .onDrop(of: [.fileURL], isTargeted: $isImportTargeted, perform: loadDroppedFile)
    }

    private var importing: some View {
        // The status is geometrically centred in the surface. The active
        // cancel affordance is overlaid at the edge and cannot shift it.
        ZStack {
            Text("hud.processing")
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: true, vertical: false)
            HStack {
                Spacer(minLength: 0)
                hudButton(symbol: "xmark", labelKey: "hud.action.cancelImport", action: stateHolder.actions.onDismiss)
            }
        }
        .padding(HUDLayout.contentInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func importFinished(text: String) -> some View {
        // The completion status stays text-only and exactly centred; Copy
        // and Close remain independent edge actions.
        ZStack {
            Text("hud.import.finished").font(.callout.weight(.medium))
            HStack {
                hudButton(symbol: "doc.on.doc", labelKey: "hud.import.copy") {
                    copyToPasteboard(text)
                    stateHolder.actions.onImportResultCopied()
                }
                Spacer(minLength: 0)
                hudButton(symbol: "xmark", labelKey: "hud.action.dismiss", action: stateHolder.actions.onDismiss)
            }
        }
        .padding(HUDLayout.contentInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func hudButton(
        symbol: String,
        labelKey: LocalizedStringKey,
        tint: Color = .primary,
        action: @escaping () -> Void
    ) -> some View {
        HUDIconButton(symbol: symbol, labelKey: labelKey, tint: tint, action: action)
    }

    private func loadDroppedFile(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                // Give AppKit exactly one display frame to retire its
                // dragged-file preview before the 144→48 pt morph. The old
                // 80 ms hold was visually safe but felt like a dropped frame
                // at the instant of release.
                isImportTargeted = false
                try? await Task.sleep(nanoseconds: 16_666_667)
                stateHolder.actions.onImportFileDropped(url)
            }
        }
        return true
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func elapsedString(_ value: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(value) / 60, Int(value) % 60)
    }

    @ViewBuilder
    private func autoDismissProgress(for state: HUDState, cornerRadius: CGFloat) -> some View {
        switch state {
        case .cancelledWithUndo, .importFinished:
            GeometryReader { proxy in
                Rectangle()
                    .fill(.primary.opacity(0.35))
                    .frame(width: proxy.size.width * stateHolder.dismissProgress, height: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .allowsHitTesting(false)
        default:
            EmptyView()
        }
    }
}

/// A shared hover state for every compact HUD control. It only changes the
/// material contrast — never the control's frame — so a pointer move cannot
/// cause the capsule to re-layout or visibly jump.
private struct HUDIconButton: View {
    let symbol: String
    let labelKey: LocalizedStringKey
    let tint: Color
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: HUDLayout.controlSize, height: HUDLayout.controlSize)
                .background(.primary.opacity(isHovered ? 0.12 : 0.05), in: Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.10)) { isHovered = hovering }
        }
        .accessibilityLabel(Text(labelKey))
    }
}

private struct HUDLayout: Equatable {
    static let hostWidth: CGFloat = 360
    static let hostHeight: CGFloat = 144
    static let controlSize: CGFloat = 28
    /// Applied by every HUD state on every edge. This is the one source of
    /// truth for capsule interiors; state-specific views never add a second
    /// horizontal or vertical inset.
    static let contentInset: CGFloat = 10

    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat

    static func forState(_ state: HUDState) -> HUDLayout {
        switch state {
        case .hidden: return HUDLayout(width: 1, height: 1, cornerRadius: 0)
        // Every 48 pt capsule is dimensioned from its fixed child controls
        // plus exactly 10 pt on each edge. The old round-number widths left
        // spare horizontal space, which SwiftUI centered as visibly larger
        // left/right margins than the 10 pt top/bottom margins.
        case .recording: return HUDLayout(width: 252, height: 48, cornerRadius: 24)
        case .processing: return HUDLayout(width: 176, height: 48, cornerRadius: 24)
        case .inserted: return HUDLayout(width: 120, height: 48, cornerRadius: 24)
        case .copied: return HUDLayout(width: 176, height: 48, cornerRadius: 24)
        case .cancelled: return HUDLayout(width: 200, height: 48, cornerRadius: 24)
        case .cancelledWithUndo: return HUDLayout(width: 176, height: 48, cornerRadius: 24)
        case .error: return HUDLayout(width: 332, height: 48, cornerRadius: 24)
        case .importIdle: return HUDLayout(width: 320, height: 144, cornerRadius: 18)
        case .importing: return HUDLayout(width: 196, height: 48, cornerRadius: 24)
        case .importFinished: return HUDLayout(width: 180, height: 48, cornerRadius: 24)
        case .importOpened: return HUDLayout(width: 208, height: 48, cornerRadius: 24)
        }
    }
}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(0..<12, id: \.self) { index in
                    Capsule()
                        .fill(.primary.opacity(index < Int(level * 12) + 2 ? 0.75 : 0.22))
                        .frame(height: 5 + CGFloat((index % 4) * 3))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

struct HUDActions {
    var onFinish: () -> Void = {}
    var onCancel: () -> Void = {}
    var onRetry: () -> Void = {}
    var onSelectMicrophone: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onImportFileDropped: (URL) -> Void = { _ in }
    var onChooseImportFile: () -> Void = {}
    var onOpenHistoryRecord: (UUID) -> Void = { _ in }
    var onSwitchToImport: () -> Void = {}
    var onResumeRecording: () -> Void = {}
    var onInteractionChanged: (Bool) -> Void = { _ in }
    var onImportResultCopied: () -> Void = {}
    var onImportResultOpened: () -> Void = {}
    var onCancelPausedDictation: () -> Void = {}
}

@MainActor
final class HUDStateHolder: ObservableObject {
    @Published var state: HUDState = .hidden
    @Published var dismissProgress: CGFloat = 0
    var actions = HUDActions()
}
