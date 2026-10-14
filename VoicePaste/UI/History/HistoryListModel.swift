import Foundation

/// Состояние раздела истории, общее для списка и детали.
///
/// Прежде жило в `@State` одного вида: список и деталь стояли в одной
/// `NavigationSplitView`. В трёх колонках это два вида, и выбор в списке
/// должен доходить до детали — поэтому состояние вынесено сюда.
@MainActor
final class HistoryListModel: ObservableObject {
    @Published private(set) var items: [TranscriptListItem] = []
    /// Первая выборка завершилась (удачно или нет). До неё «Нет записей» — ложь.
    @Published private(set) var isLoaded = false
    /// Удаление не прошло, строка вернулась на место. Сбрасывает показавший отказ.
    @Published var didFailToDelete = false
    @Published var searchText = "" {
        didSet { if searchText != oldValue { scheduleSearch(searchText) } }
    }
    @Published var selection: UUID? {
        didSet {
            // Выбор снят сейчас, а не когда задача дойдёт до исполнения: два
            // быстрых выбора иначе оба читают последний.
            if selection != oldValue { select(selection) }
        }
    }
    @Published var detail: Transcript?

    /// За сколько строк до конца начинается подгрузка следующей страницы.
    private static let prefetchDistance = 20
    /// Потолок глубины, которую обновление восстанавливает одним заходом.
    private static let maxRefreshPages = 30

    private let store: any HistoryStoring
    private var nextCursor: TranscriptCursor?
    private var searchTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var isLoadingNextPage = false
    /// Растёт при каждой замене списка: ответ подгрузки, начатой до замены, чужой.
    private var generation = 0
    /// Строки, которые уже убраны с экрана, а база ещё не подтвердила удаление.
    private var pendingDeletions: Set<UUID> = []

    /// Хранилище приходит при создании, а не подключается потом.
    ///
    /// Прежде подключалось в `onAppear`, а загрузка шла из `.task`, и SwiftUI
    /// не обещает, что `onAppear` выполнится первым. 21.09.2026 на живой
    /// машине `.task` успел раньше: загрузка увидела пустое хранилище, вышла,
    /// и история не появилась вовсе. Порядка, от которого зависит результат,
    /// теперь нет.
    init(store: any HistoryStoring) {
        self.store = store
    }

    /// Хранилище, на котором стоит модель: редактору детали нужна запись правки.
    var historyStore: any HistoryStoring { store }

    /// Bug fix: the main `Window` scene is long-lived — without this, a list
    /// loaded once at first appearance never reflected transcripts saved
    /// afterwards until the window was closed and reopened.
    /// `HistoryStoring.changes()` ticks immediately on subscribe (covering the
    /// first load) and again after every `save`/`edit`/`delete`/`clearAll`.
    func observeChanges() async {
        for await _ in store.changes() {
            await reload(query: searchText, minimumCount: items.count)
        }
    }

    func loadNextPageIfNeeded(current: TranscriptListItem) {
        guard !isLoadingNextPage, let cursor = nextCursor,
              items.suffix(Self.prefetchDistance).contains(where: { $0.id == current.id })
        else { return }
        isLoadingNextPage = true
        let startedAt = generation
        let query = searchText
        Task {
            defer { isLoadingNextPage = false }
            guard let page = await fetch(query: query, after: cursor), generation == startedAt else { return }
            let known = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter {
                !known.contains($0.id) && !pendingDeletions.contains($0.id)
            })
            nextCursor = page.nextCursor
        }
    }

    /// Строка уходит с экрана сразу; база подтверждает позже, а при отказе
    /// строка возвращается на то же место.
    func delete(id transcriptID: UUID) {
        let removed = items.firstIndex { $0.id == transcriptID }.map { (index: $0, item: items[$0]) }
        let neighbour = removed.flatMap { removed -> UUID? in
            if items.indices.contains(removed.index + 1) { return items[removed.index + 1].id }
            return removed.index > 0 ? items[removed.index - 1].id : nil
        }
        pendingDeletions.insert(transcriptID)
        items.removeAll { $0.id == transcriptID }
        if selection == transcriptID { selection = neighbour }
        if detail?.id == transcriptID { detail = nil }

        Task {
            defer { pendingDeletions.remove(transcriptID) }
            do {
                try await store.delete(id: transcriptID)
            } catch {
                await DiagnosticLog.shared.log("history.deleteFailed", detail: String(describing: error))
                if let removed, !items.contains(where: { $0.id == transcriptID }) {
                    items.insert(removed.item, at: min(removed.index, items.count))
                }
                didFailToDelete = true
            }
        }
    }

    /// Перечитывает запрос от начала и пока не наберёт `minimumCount` строк:
    /// тик обновления не должен схлопывать уже подгруженное и сбрасывать прокрутку.
    private func reload(query: String, minimumCount: Int) async {
        var collected: [TranscriptListItem] = []
        var cursor: TranscriptCursor?
        var pages = 0
        repeat {
            guard let page = await fetch(query: query, after: cursor) else {
                isLoaded = true
                return
            }
            collected += page.items
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && collected.count < minimumCount && pages < Self.maxRefreshPages
        guard !Task.isCancelled, query == searchText else { return }
        generation += 1
        items = collected.filter { !pendingDeletions.contains($0.id) }
        nextCursor = cursor
        isLoaded = true
    }

    private func fetch(query: String, after cursor: TranscriptCursor?) async -> TranscriptPage? {
        do {
            return query.isEmpty
                ? try await store.fetchPage(after: cursor)
                : try await store.search(query: query, after: cursor)
        } catch {
            await DiagnosticLog.shared.log("history.loadFailed", detail: String(describing: error))
            return nil
        }
    }

    private func select(_ id: UUID?) {
        detailTask?.cancel()
        guard let id else {
            detail = nil
            return
        }
        detailTask = Task { await loadDetail(id: id) }
    }

    private func loadDetail(id: UUID) async {
        let loaded = try? await store.fetchDetail(id: id)
        // Ответ на прежний выбор не должен перетирать нынешний.
        guard !Task.isCancelled, selection == id else { return }
        detail = loaded
    }

    /// `L-008`: 250 ms debounce, cancels the stale request before it ever
    /// reaches the store; Enter never starts a recognition session.
    private func scheduleSearch(_ query: String) {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await reload(query: query, minimumCount: 0)
        }
    }
}
