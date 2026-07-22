import SwiftUI

/// `UI-004`: the app's single permanent window, one real `NavigationSplitView`.
/// Sidebar pages 100 rows at a time via `HistoryStoring` (`DM-002`/`DM-003`),
/// never loading `rawText` or full `text` until an item is selected. Search
/// is FTS5-backed with a 250 ms debounce that cancels stale requests
/// (`L-008`). No external section navigation, no Dashboard, no Settings
/// inside this window — dictation/import work happens in the transient HUD.
struct HistoryView: View {
    @EnvironmentObject private var appState: AppState
    @Binding private var section: MainContentSection
    @State private var items: [TranscriptListItem] = []
    @State private var nextCursor: TranscriptCursor?
    @State private var searchText = ""
    @State private var selection: UUID?
    @State private var detail: Transcript?
    @State private var searchTask: Task<Void, Never>?
    @State private var showingDeleteConfirmation = false
    @State private var sidebarDeleteID: UUID?

    init(section: Binding<MainContentSection>) {
        _section = section
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 380)
                .searchable(
                    text: $searchText,
                    placement: .sidebar,
                    prompt: Text("history.search.prompt")
                )
        } detail: {
            detailView
                .frame(minWidth: detailMinWidth)
        }
        .onChange(of: searchText) { _, newValue in scheduleSearch(newValue) }
        .onChange(of: selection) { _, newValue in
            if newValue != nil, section != .history {
                section = .history
            }
            Task { await loadDetail(id: newValue) }
        }
        .task { await observeHistoryChanges() }
        .onChange(of: appState.requestedHistorySelection) { _, newValue in
            guard let newValue else { return }
            selection = newValue
            appState.requestedHistorySelection = nil
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    appState.openStatistics()
                } label: {
                    Label("Статистика", systemImage: "chart.bar.xaxis")
                }
                .labelStyle(.iconOnly)
                .help("Статистика")
                .accessibilityLabel(Text("Статистика"))
                .disabled(section == .dashboard)

                Button {
                    appState.handleHotkeyDown()
                } label: {
                    Label("history.toolbar.startDictation", systemImage: "waveform")
                }
                .labelStyle(.iconOnly)
                .help("history.toolbar.startDictation")
                .accessibilityLabel(Text("history.toolbar.startDictation"))
                // `INV-015`/`AT-088`: recording stays a disabled, non-erroring
                // control while not ready, not a tap that surfaces an error.
                .disabled(appState.dictationPhase == .processing || appState.readiness.state != .ready)

                Button {
                    appState.openImportQueue()
                } label: {
                    Label("history.toolbar.transcribeFile", systemImage: "arrow.down.doc")
                }
                .labelStyle(.iconOnly)
                .help("history.toolbar.transcribeFile")
                .accessibilityLabel(Text("history.toolbar.transcribeFile"))
                // `INV-015`/`AT-088`: import stays disabled while not ready.
                .disabled(appState.readiness.state != .ready)

                Button {
                    copyCurrentTranscript()
                } label: {
                    Label("history.toolbar.copy", systemImage: "doc.on.doc")
                }
                .labelStyle(.iconOnly)
                .help("Копировать")
                .accessibilityLabel(Text("Копировать"))
                .disabled(!canActOnSelection)

                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label("history.toolbar.delete", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .help("Удалить запись")
                .accessibilityLabel(Text("Удалить запись"))
                .disabled(!canActOnSelection)
            }
        }
        .confirmationDialog(
            "history.toolbar.deleteConfirmTitle",
            isPresented: $showingDeleteConfirmation
        ) {
            Button("history.toolbar.deleteConfirmAction", role: .destructive) {
                deleteCurrentTranscript()
            }
        }
        .confirmationDialog(
            "history.toolbar.deleteConfirmTitle",
            isPresented: sidebarDeleteConfirmation
        ) {
            Button("history.toolbar.deleteConfirmAction", role: .destructive) {
                guard let sidebarDeleteID else { return }
                deleteTranscript(id: sidebarDeleteID)
                self.sidebarDeleteID = nil
            }
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        let activeImports = appState.importManager.jobs.filter(\.state.isActive)
        if items.isEmpty && activeImports.isEmpty {
            ContentUnavailableView(
                "history.empty.title",
                systemImage: "waveform",
                description: Text("history.empty.description")
            )
        } else {
            List(selection: $selection) {
                if !activeImports.isEmpty && searchText.isEmpty {
                    Section("В процессе") {
                        ForEach(activeImports) { job in
                            ProcessingImportRow(job: job) {
                                appState.openImportQueue()
                            }
                        }
                    }
                }
                if !items.isEmpty {
                    Section {
                        ForEach(items) { item in
                            HistoryRow(item: item)
                                .tag(item.id)
                                .onAppear { loadNextPageIfNeeded(current: item) }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        sidebarDeleteID = item.id
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

    private var detailMinWidth: CGFloat { 520 }

    private var sidebarDeleteConfirmation: Binding<Bool> {
        Binding(
            get: { sidebarDeleteID != nil },
            set: { if !$0 { sidebarDeleteID = nil } }
        )
    }

    /// The toolbar itself never changes its structure when statistics opens:
    /// record-specific actions simply become inactive. This prevents AppKit
    /// from re-laying-out and visually jumping the toolbar during a section
    /// transition while keeping dictation and file import immediately ready.
    private var canActOnSelection: Bool {
        section == .history && detail != nil
    }

    @ViewBuilder
    private var detailView: some View {
        if section == .dashboard {
            DashboardView()
        } else if section == .importQueue {
            ImportQueueView()
        } else if let detail {
            DetailEditor(
                transcript: detail,
                onChange: { updated in self.detail = updated }
            )
        } else {
            ContentUnavailableView("history.detail.empty", systemImage: "text.bubble")
        }
    }

    private func loadFirstPage() async {
        guard let page = try? await appState.historyStore.fetchPage(after: nil) else { return }
        items = page.items
        nextCursor = page.nextCursor
    }

    /// Bug fix: `HistoryView`'s `Window` scene is long-lived — without this,
    /// a list loaded once via `.task` at first appearance never reflected
    /// transcripts saved afterwards until the window was closed and
    /// reopened. `HistoryStoring.changes()` ticks immediately on subscribe
    /// (covering the original first-load) and again after every
    /// `save`/`edit`/`delete`/`clearAll`, so this single loop replaces the
    /// old one-shot `loadFirstPage()` call in `body` entirely.
    private func observeHistoryChanges() async {
        for await _ in appState.historyStore.changes() {
            await refreshCurrentQuery()
        }
    }

    /// Re-runs whichever query the sidebar is currently showing (first page,
    /// or the active search) at its first page — a live tick resets to the
    /// top of the list rather than trying to preserve a mid-pagination
    /// scroll position, same as re-opening the window would.
    private func refreshCurrentQuery() async {
        if searchText.isEmpty {
            await loadFirstPage()
            return
        }
        guard let page = try? await appState.historyStore.search(query: searchText, after: nil) else { return }
        items = page.items
        nextCursor = page.nextCursor
    }

    private func loadNextPageIfNeeded(current: TranscriptListItem) {
        guard current.id == items.last?.id, let cursor = nextCursor else { return }
        Task {
            guard let page = try? await appState.historyStore.fetchPage(after: cursor) else { return }
            items.append(contentsOf: page.items)
            nextCursor = page.nextCursor
        }
    }

    private func loadDetail(id: UUID?) async {
        guard let id else {
            detail = nil
            return
        }
        detail = try? await appState.historyStore.fetchDetail(id: id)
    }

    private func copyCurrentTranscript() {
        guard let detail else { return }
        TextInserter.copyToClipboard(detail.text)
    }

    private func deleteCurrentTranscript() {
        guard let detail else { return }
        deleteTranscript(id: detail.id)
    }

    private func deleteTranscript(id transcriptID: UUID) {
        Task {
            try? await appState.historyStore.delete(id: transcriptID)
            if selection == transcriptID {
                self.detail = nil
                self.selection = nil
            }
            await loadFirstPage()
        }
    }

    /// `L-008`: 250 ms debounce, cancels the stale request before it ever
    /// reaches the store; Enter never starts a recognition session.
    private func scheduleSearch(_ query: String) {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            if query.isEmpty {
                await loadFirstPage()
                return
            }
            guard let page = try? await appState.historyStore.search(query: query, after: nil) else { return }
            guard !Task.isCancelled else { return }
            items = page.items
            nextCursor = page.nextCursor
        }
    }

}

private struct HistoryRow: View {
    let item: TranscriptListItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.preview.isEmpty ? " " : item.preview)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(item.createdAt.formattedHistoryDate())
                Text(durationString(item.durationMilliseconds))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
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
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
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
                HStack(spacing: 7) {
                    Text(job.displayStage)
                    ProgressView(value: job.progress)
                        .progressViewStyle(.linear)
                        .tint(Color.accentColor)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
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
