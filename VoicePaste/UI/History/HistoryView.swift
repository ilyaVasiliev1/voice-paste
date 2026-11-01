import SwiftUI

/// Список раздела истории: записи с поиском и секцией незавершённого импорта.
/// Sidebar pages 100 rows at a time via `HistoryStoring`,
/// never loading `rawText` or full `text` until an item is selected. Search
/// is FTS5-backed with a short debounce that cancels stale requests
/// (`L-008`, в `HistoryListModel`).
struct HistoryListColumn: View {
    /// Не наблюдается: нужен для перехода в очередь, а перерисовку от лекции
    /// и модели список получать не должен.
    private let appState: AppState
    @ObservedObject private var importManager: ImportManager
    @ObservedObject var model: HistoryListModel
    @State private var deleteID: UUID?

    init(model: HistoryListModel, appState: AppState) {
        self.model = model
        self.appState = appState
        _importManager = ObservedObject(wrappedValue: appState.importManager)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("history.search.prompt", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Очистить поиск")
                }
            }
            .padding(10)
            .background(WorkspacePalette.sidebar, in: RoundedRectangle(cornerRadius: 6))
            .padding(12)
            list.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
            .alert("history.deleteFailed.title", isPresented: $model.didFailToDelete) {
                Button("common.ok", role: .cancel) {}
            } message: {
                Text("history.deleteFailed.message")
            }
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
        let activeImports = importManager.jobs.filter(\.state.isActive)
        if !model.isLoaded && activeImports.isEmpty {
            HistoryLoadingPlaceholder()
        } else if model.didFailToLoad && model.items.isEmpty && activeImports.isEmpty {
            ContentUnavailableView {
                Label("history.loadFailed.title", systemImage: "exclamationmark.triangle")
            } description: {
                Text("history.loadFailed.description")
            } actions: {
                Button("history.loadFailed.retry") { Task { await model.retry() } }
            }
        } else if model.items.isEmpty && activeImports.isEmpty {
            ContentUnavailableView(
                model.searchText.isEmpty ? "history.empty.title" : "history.list.empty.title",
                systemImage: "waveform",
                description: model.searchText.isEmpty ? Text("history.empty.description") : nil
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if !activeImports.isEmpty && model.searchText.isEmpty {
                        Text("В процессе").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.top, 8)
                        ForEach(activeImports) { job in
                            ProcessingImportRow(job: job) { appState.openImportQueue() }
                                .padding(12)
                        }
                    }
                    ForEach(model.items) { item in
                        Button { model.selection = item.id } label: {
                            HistoryRow(item: item).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(WorkspaceRowStyle(selected: model.selection == item.id))
                        .accessibilityAddTraits(model.selection == item.id ? [.isSelected] : [])
                        .onAppear { model.loadNextPageIfNeeded(current: item) }
                        .contextMenu {
                            Button(role: .destructive) { deleteID = item.id } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
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
    @ObservedObject var model: HistoryListModel
    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(title: "Расшифровка") {
                StartDictationButton()
                Button {
                    guard let detail = model.detail else { return }
                    TextInserter.copyToClipboard(detail.text)
                } label: { Image(systemName: "doc.on.doc") }
                .help("Копировать").accessibilityLabel("Копировать")
                .disabled(model.detail == nil)
                Button(role: .destructive) { showingDeleteConfirmation = true } label: {
                    Image(systemName: "trash")
                }
                .help("Удалить запись").accessibilityLabel("Удалить запись")
                .disabled(model.detail == nil)
            }
            .buttonStyle(WorkspaceActionStyle())
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
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
                store: model.historyStore,
                onChange: { updated in model.detail = updated }
            )
            // Новая запись — новый редактор: текст на первом кадре, а не после .task.
            .id(detail.id)
        } else if model.didFailToOpenDetail {
            ContentUnavailableView("history.detail.failed", systemImage: "exclamationmark.triangle")
        } else {
            ContentUnavailableView("history.detail.empty", systemImage: "text.bubble")
        }
    }
}

/// Единственное место раздела, которому нужно состояние всего приложения:
/// остальное в детали за этим не следит и не перерисовывается от лекции.
private struct StartDictationButton: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Button {
            appState.handleHotkeyDown()
        } label: {
            Label("history.toolbar.startDictation", systemImage: "waveform")
        }
        .buttonStyle(WorkspaceActionStyle(primary: true))
        .help("history.toolbar.startDictation")
        // recording stays a disabled, non-erroring
        // control while not ready, not a tap that surfaces an error.
        .disabled(appState.dictationPhase == .processing || appState.readiness.state != .ready)
    }
}

/// Заглушка списка на время первой выборки. Показывается не сразу: выборка
/// обычно короче, и вспышка серых строк была бы тем же мерцанием.
private struct HistoryLoadingPlaceholder: View {
    @State private var isVisible = false

    private static let sample = TranscriptListItem(
        id: UUID(), createdAt: 0, updatedAt: 0, source: .dictation, sourceFileName: nil,
        durationMilliseconds: 0, language: nil, preview: "Заглушка строки истории на время загрузки",
        status: .completed, insertionOutcome: .notRequested
    )

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(0..<7, id: \.self) { _ in HistoryRow(item: Self.sample) }
            }.padding(20)
        }
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
        .opacity(isVisible ? 1 : 0)
        .task {
            try? await Task.sleep(for: .milliseconds(150))
            isVisible = true
        }
    }
}

private struct HistoryRow: View {
    let item: TranscriptListItem

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: item.source == .dictation ? "mic" : "doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(item.sourceFileName ?? NSLocalizedString("history.source.dictation", comment: ""))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(item.preview.isEmpty ? " " : item.preview)
                .font(.system(size: 13))
                .lineSpacing(2)
                .lineLimit(3)
            HStack(spacing: DesignTokens.Spacing.sm) {
                Text(DisplayFormat.recordDate(Date(timeIntervalSince1970: Double(item.createdAt) / 1_000)))
                Text("·")
                Text(DisplayFormat.duration(milliseconds: item.durationMilliseconds))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, DesignTokens.Spacing.sm)
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
