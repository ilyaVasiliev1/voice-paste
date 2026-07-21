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
            try? await appState.historyStore.edit(id: transcript.id, text: newText, updatedAt: now)
            var updated = transcript
            updated.text = newText
            updated.preview = Transcript.makePreview(from: newText)
            updated.updatedAt = now
            onChange(updated)
        }
    }

}
