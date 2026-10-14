import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Правка текста записи: показ, откладывание записи, отказ.
///
/// Вынесена из вида, чтобы тест видел то, что слой SwiftUI не показывает:
/// просмотр записи ничего не пишет, а текст готов к первому кадру. Прежде
/// `.task` подставлял текст после первого кадра, и `onChange` принимал эту
/// подстановку за правку: каждый выбор записи был UPDATE и перезагрузкой списка.
@MainActor
final class DetailEditModel: ObservableObject {
    @Published private(set) var text: String
    /// Правка не записалась. Поднято, чтобы отказ не выглядел успехом: без
    /// него экран показывал сохранённый текст, а в базе оставался прежний.
    @Published private(set) var didFailToSave = false

    private let transcript: Transcript
    private let store: any HistoryStoring
    private let debounce: Duration
    private let onSaved: (Transcript) -> Void
    private var saveTask: Task<Void, Never>?

    init(
        transcript: Transcript,
        store: any HistoryStoring,
        debounce: Duration = .milliseconds(500),
        onSaved: @escaping (Transcript) -> Void
    ) {
        self.transcript = transcript
        self.store = store
        self.debounce = debounce
        self.onSaved = onSaved
        self.text = transcript.text
    }

    /// Только ввод человека: программная подстановка сюда не приходит.
    func userEdited(_ newText: String) {
        guard newText != text else { return }
        text = newText
        saveTask?.cancel()
        // Задача держит модель: уход на другую запись не теряет ожидающую правку.
        saveTask = Task {
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await save(newText)
        }
    }

    private func save(_ newText: String) async {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        do {
            try await store.edit(id: transcript.id, text: newText, updatedAt: now)
        } catch {
            // Раньше запись шла через `try?`, а обновление модели вызывалось
            // следом безусловно: список и деталь показывали новый текст,
            // которого в базе нет, и до перезапуска это было незаметно.
            didFailToSave = true
            await DiagnosticLog.shared.log("history.editFailed", detail: String(describing: error))
            return
        }
        didFailToSave = false
        var updated = transcript
        updated.text = newText
        updated.preview = Transcript.makePreview(from: newText)
        updated.updatedAt = now
        onSaved(updated)
    }
}

/// Detail pane of editable text, metadata, copying, and a compact
/// destructive action. `rawText` is preserved on edit; only
/// `text`/`preview`/`updatedAt` change.
struct DetailEditor: View {
    let transcript: Transcript
    @StateObject private var model: DetailEditModel

    init(transcript: Transcript, store: any HistoryStoring, onChange: @escaping (Transcript) -> Void) {
        self.transcript = transcript
        _model = StateObject(wrappedValue: DetailEditModel(transcript: transcript, store: store, onSaved: onChange))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            header
            TextEditor(text: Binding(get: { model.text }, set: { model.userEdited($0) }))
                .font(.body)
                .lineSpacing(3)
        }
        .frame(maxWidth: DesignTokens.readingMeasure, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.detailPanePadding)
    }

    /// Дата записи — заголовок, остальное — тихой строкой под ним.
    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(DisplayFormat.recordDate(Date(timeIntervalSince1970: Double(transcript.createdAt) / 1_000)))
                    .font(.title3.weight(.semibold))
                if model.didFailToSave {
                    Spacer()
                    Label(
                        NSLocalizedString("history.detail.saveFailed", comment: ""),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("detail-save-failed")
                }
            }
            Text(details)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // У текстового поля свой внутренний отступ — без него левый край шапки уходит от текста.
        .padding(.leading, 5)
    }

    private var details: String {
        [sourceText, durationString, DisplayFormat.languageName(transcript.language)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var sourceText: String {
        switch transcript.source {
        case .dictation: return NSLocalizedString("history.source.dictation", comment: "")
        case .file: return transcript.sourceFileName ?? NSLocalizedString("history.source.file", comment: "")
        }
    }

    private var durationString: String {
        DisplayFormat.duration(milliseconds: transcript.durationMilliseconds)
    }
}
