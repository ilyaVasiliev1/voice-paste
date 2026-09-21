import Foundation

/// Состояние раздела истории, общее для списка и детали.
///
/// Прежде жило в `@State` одного вида: список и деталь стояли в одной
/// `NavigationSplitView`. В трёх колонках это два вида, и выбор в списке
/// должен доходить до детали — поэтому состояние вынесено сюда.
@MainActor
final class HistoryListModel: ObservableObject {
    @Published private(set) var items: [TranscriptListItem] = []
    @Published var searchText = "" {
        didSet { if searchText != oldValue { scheduleSearch(searchText) } }
    }
    @Published var selection: UUID? {
        didSet {
            // Выбор снят сейчас, а не когда задача дойдёт до исполнения: два
            // быстрых выбора иначе оба читают последний.
            let id = selection
            if id != oldValue { Task { await loadDetail(id: id) } }
        }
    }
    @Published var detail: Transcript?

    private var store: (any HistoryStoring)?
    private var nextCursor: TranscriptCursor?
    private var searchTask: Task<Void, Never>?

    /// Хранилище приходит из окружения вида, а не при создании: модель
    /// создаётся раньше, чем вид получает `AppState`.
    ///
    /// Выбор, сделанный до подключения, догружается здесь: «Открыть в истории»
    /// из плашки выбирает запись при появлении окна, и загрузка по этому выбору
    /// могла пройти ещё без хранилища — деталь оставалась пустой навсегда.
    func attach(_ store: any HistoryStoring) {
        guard self.store == nil else { return }
        self.store = store
        if let selection, detail == nil {
            Task { await loadDetail(id: selection) }
        }
    }

    /// Bug fix: the main `Window` scene is long-lived — without this, a list
    /// loaded once at first appearance never reflected transcripts saved
    /// afterwards until the window was closed and reopened.
    /// `HistoryStoring.changes()` ticks immediately on subscribe (covering the
    /// first load) and again after every `save`/`edit`/`delete`/`clearAll`.
    func observeChanges() async {
        guard let store else { return }
        for await _ in store.changes() {
            await refreshCurrentQuery()
        }
    }

    func loadNextPageIfNeeded(current: TranscriptListItem) {
        guard current.id == items.last?.id, let cursor = nextCursor, let store else { return }
        Task {
            guard let page = try? await store.fetchPage(after: cursor) else { return }
            items.append(contentsOf: page.items)
            nextCursor = page.nextCursor
        }
    }

    func delete(id transcriptID: UUID) {
        guard let store else { return }
        Task {
            try? await store.delete(id: transcriptID)
            if selection == transcriptID {
                detail = nil
                selection = nil
            }
            await loadFirstPage()
        }
    }

    /// Re-runs whichever query the list is currently showing at its first
    /// page — a live tick resets to the top rather than preserving a
    /// mid-pagination scroll position, same as re-opening the window would.
    private func refreshCurrentQuery() async {
        if searchText.isEmpty {
            await loadFirstPage()
            return
        }
        guard let page = try? await store?.search(query: searchText, after: nil) else { return }
        items = page.items
        nextCursor = page.nextCursor
    }

    private func loadFirstPage() async {
        guard let page = try? await store?.fetchPage(after: nil) else { return }
        items = page.items
        nextCursor = page.nextCursor
    }

    private func loadDetail(id: UUID?) async {
        guard let id else {
            detail = nil
            return
        }
        detail = try? await store?.fetchDetail(id: id)
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
            guard let page = try? await store?.search(query: query, after: nil) else { return }
            guard !Task.isCancelled else { return }
            items = page.items
            nextCursor = page.nextCursor
        }
    }
}
