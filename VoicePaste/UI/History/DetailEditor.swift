import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Detail pane of `UI-004`: editable text, metadata, copying, and a compact
/// destructive action. `rawText` is preserved on edit (`L-008`); only
/// `text`/`preview`/`updatedAt` change.
struct DetailEditor: View {
    @EnvironmentObject private var appState: AppState
    let transcript: Transcript
    let onChange: (Transcript) -> Void

    @State private var editedText: String = ""
    @State private var saveTask: Task<Void, Never>?
    /// Правка не записалась. Поднято, чтобы отказ не выглядел успехом: без
    /// него экран показывал сохранённый текст, а в базе оставался прежний.
    @State private var didFailToSave = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            metadata
            TextEditor(text: $editedText)
                .font(.body)
                .onChange(of: editedText) { _, newValue in scheduleSave(newValue) }
        }
        .padding()
        .task(id: transcript.id) {
            editedText = transcript.text
        }
    }

    private var metadata: some View {
        HStack(spacing: 12) {
            Label(sourceText, systemImage: transcript.source == .file ? "doc" : "mic")
            Text(durationString)
            if let language = transcript.language {
                Text(language.uppercased())
            }
            if didFailToSave {
                Spacer()
                Label(
                    NSLocalizedString("history.detail.saveFailed", comment: ""),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .accessibilityIdentifier("detail-save-failed")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var sourceText: String {
        switch transcript.source {
        case .dictation: return NSLocalizedString("history.source.dictation", comment: "")
        case .file: return transcript.sourceFileName ?? NSLocalizedString("history.source.file", comment: "")
        }
    }

    private var durationString: String {
        let totalSeconds = transcript.durationMilliseconds / 1_000
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func scheduleSave(_ newText: String) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            do {
                try await appState.historyStore.edit(id: transcript.id, text: newText, updatedAt: now)
            } catch {
                // Раньше запись шла через `try?`, а обновление модели вызывалось
                // следом безусловно: список и деталь показывали новый текст,
                // которого в базе нет, и до перезапуска это было незаметно.
                // Теперь правка не расходится с хранилищем — и отказ виден.
                didFailToSave = true
                await DiagnosticLog.shared.log(
                    "history.editFailed",
                    detail: String(describing: error)
                )
                return
            }
            didFailToSave = false
            var updated = transcript
            updated.text = newText
            updated.preview = Transcript.makePreview(from: newText)
            updated.updatedAt = now
            onChange(updated)
        }
    }

}
