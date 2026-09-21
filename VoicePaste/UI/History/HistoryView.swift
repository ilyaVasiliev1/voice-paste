import SwiftUI

/// Список раздела истории: записи с поиском и секцией незавершённого импорта.
/// Sidebar pages 100 rows at a time via `HistoryStoring` (`DM-002`/`DM-003`),
/// never loading `rawText` or full `text` until an item is selected. Search
/// is FTS5-backed with a 250 ms debounce that cancels stale requests
/// (`L-008`, в `HistoryListModel`).
struct HistoryListColumn: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var model: HistoryListModel
    @State private var deleteID: UUID?

    var body: some View {
        list
            .searchable(text: $model.searchText, prompt: Text("history.search.prompt"))
            .confirmationDialog(
                "history.toolbar.deleteConfirmTitle",
                isPresented: deleteConfirmation
            ) {
                Button("history.toolbar.deleteConfirmAction", role: .destructive) {
                    guard let deleteID else { return }
                    model.delete(id: deleteID)
                    self.deleteID = nil
                }
            }
    }

    @ViewBuilder
    private var list: some View {
        let activeImports = appState.importManager.jobs.filter(\.state.isActive)
        if model.items.isEmpty && activeImports.isEmpty {
            ContentUnavailableView(
                model.searchText.isEmpty ? "history.empty.title" : "history.list.empty.title",
                systemImage: "waveform",
                description: model.searchText.isEmpty ? Text("history.empty.description") : nil
            )
        } else {
            List(selection: $model.selection) {
                if !activeImports.isEmpty && model.searchText.isEmpty {
                    Section("В процессе") {
                        ForEach(activeImports) { job in
                            ProcessingImportRow(job: job) {
                                appState.openImportQueue()
                            }
                        }
                    }
                }
                if !model.items.isEmpty {
                    Section {
                        ForEach(model.items) { item in
                            HistoryRow(item: item)
                                .tag(item.id)
                                .onAppear { model.loadNextPageIfNeeded(current: item) }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        deleteID = item.id
                                    } label: {
                                        Label("Удалить", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
        }
    }

    private var deleteConfirmation: Binding<Bool> {
        Binding(
            get: { deleteID != nil },
            set: { if !$0 { deleteID = nil } }
        )
    }
}

/// Деталь раздела истории: текст выбранной записи и действия над ней.
struct HistoryDetailColumn: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var model: HistoryListModel
    @State private var showingDeleteConfirmation = false

    var body: some View {
        content
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        appState.handleHotkeyDown()
                    } label: {
                        Label("history.toolbar.startDictation", systemImage: "waveform")
                    }
                    .help("history.toolbar.startDictation")
                    // `INV-015`/`AT-088`: recording stays a disabled, non-erroring
                    // control while not ready, not a tap that surfaces an error.
                    .disabled(appState.dictationPhase == .processing || appState.readiness.state != .ready)

                    Button {
                        guard let detail = model.detail else { return }
                        TextInserter.copyToClipboard(detail.text)
                    } label: {
                        Label("history.toolbar.copy", systemImage: "doc.on.doc")
                    }
                    .help("Копировать")
                    .disabled(model.detail == nil)

                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("history.toolbar.delete", systemImage: "trash")
                    }
                    .help("Удалить запись")
                    .disabled(model.detail == nil)
                }
            }
            .confirmationDialog(
                "history.toolbar.deleteConfirmTitle",
                isPresented: $showingDeleteConfirmation
            ) {
                Button("history.toolbar.deleteConfirmAction", role: .destructive) {
                    guard let detail = model.detail else { return }
                    model.delete(id: detail.id)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let detail = model.detail {
            DetailEditor(
                transcript: detail,
                onChange: { updated in model.detail = updated }
            )
        } else {
            ContentUnavailableView("history.detail.empty", systemImage: "text.bubble")
        }
    }
}

private struct HistoryRow: View {
    let item: TranscriptListItem

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(item.preview.isEmpty ? " " : item.preview)
                .lineLimit(2)
            HStack(spacing: DesignTokens.Spacing.sm) {
                Text(item.createdAt.formattedHistoryDate())
                Text(durationString(item.durationMilliseconds))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    private func durationString(_ milliseconds: Int) -> String {
        let totalSeconds = milliseconds / 1_000
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

/// A transient queue item, deliberately not a `Transcript`. It appears in
/// the same sidebar only while there is genuinely unfinished local work, so
/// the user can see a background video without polluting search/history.
private struct ProcessingImportRow: View {
    let job: ImportJob
    let openQueue: () -> Void

    var body: some View {
        Button(action: openQueue) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: job.mediaKind == .video ? "film" : "waveform")
                        .foregroundStyle(.secondary)
                    Text(job.fileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(progressText)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Text(job.displayStage)
                    ProgressView(value: job.progress)
                        .progressViewStyle(.linear)
                        .tint(Color.accentColor)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, DesignTokens.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Открыть очередь импорта")
    }

    private var progressText: String {
        job.state == .queued || job.state == .staging ? "" : "\(Int((job.progress * 100).rounded()))%"
    }
}

private extension Int64 {
    func formattedHistoryDate() -> String {
        let date = Date(timeIntervalSince1970: Double(self) / 1_000)
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
