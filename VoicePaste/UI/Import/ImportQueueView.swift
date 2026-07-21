import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The right-side import workspace. It intentionally never replaces the
/// history sidebar: Finder and drag-and-drop are just two inputs for the
/// same persistent `ImportManager` queue.
struct ImportQueueView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isDropTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if appState.importManager.jobs.isEmpty {
                    dropStage
                } else {
                    // Keep the same drop stage after a job arrives. Forcing
                    // the existing 190 pt content into 150 pt made SwiftUI
                    // compress and overflow it into the header, so the two
                    // states looked like unrelated designs.
                    dropStage
                    queue
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: acceptDrop)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Добавить файл")
                .font(.title2.weight(.semibold))
            Text("Аудио и видео обрабатываются локально и по очереди.")
                .foregroundStyle(.secondary)
        }
    }

    private var dropStage: some View {
        Button(action: openPanel) {
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 29, weight: .medium))
                    .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
                Text("Перетащите аудио или видео сюда")
                    .font(.headline)
                Text("или нажмите, чтобы выбрать файл в Finder")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("MP3, M4A, WAV, OGG, MP4, MOV, M4V")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 190)
            .padding(20)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            isDropTargeted ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.18),
                    style: StrokeStyle(lineWidth: 1, dash: [6, 5])
                )
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.14), value: isDropTargeted)
        .accessibilityLabel("Добавить аудио или видео")
        .accessibilityHint("Открывает Finder для выбора файла")
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Очередь")
                .font(.headline)
            ForEach(appState.importManager.jobs) { job in
                QueueRow(
                    job: job,
                    canRetry: appState.importManager.canRetry(id: job.id),
                    onRetry: {
                        Task { await appState.importManager.retry(id: job.id) }
                    },
                    onRemove: {
                        if job.state == .failed {
                            appState.importManager.dismissFailed(id: job.id)
                        } else {
                            appState.importManager.cancel(id: job.id)
                        }
                    }
                )
            }
        }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ImportPanelPresenter.allowedContentTypes
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls { _ = appState.enqueueFileImport(url) }
        }
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        let available = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !available.isEmpty else { return false }
        for provider in available {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in _ = appState.enqueueFileImport(url) }
            }
        }
        return true
    }
}

private struct QueueRow: View {
    let job: ImportJob
    let canRetry: Bool
    let onRetry: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: job.mediaKind == .video ? "film" : "waveform")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 5) {
                Text(job.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if job.state == .failed, let failureKey = job.failureKey {
                    Text(LocalizedStringKey(failureKey))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    HStack(spacing: 7) {
                        Text(job.displayStage)
                        if job.state.isActive { Text(remainingText).monospacedDigit() }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if job.state.isActive {
                        ProgressView(value: job.progress)
                            .progressViewStyle(.linear)
                            .tint(job.state == .queued || job.state == .staging ? .secondary : .accentColor)
                    }
                }
            }
            Spacer(minLength: 8)
            if job.state == .failed {
                if canRetry {
                    Button(action: onRetry) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Повторить расшифровку")
                }
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Удалить файл из очереди")
            } else {
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Отменить")
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var remainingText: String {
        guard job.progress >= 0.10 else { return "Считаем время…" }
        let elapsed = max(0, Date().timeIntervalSince1970 - Double(job.stageStartedAt) / 1_000)
        let remaining = elapsed * (1 - job.progress) / max(job.progress, 0.01)
        guard remaining.isFinite, remaining >= 1 else { return "Почти готово" }
        return "≈ \(duration(remaining))"
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let value = Int(seconds.rounded())
        return value >= 60 ? "\(value / 60) мин" : "\(value) с"
    }
}
