import GRDB
import XCTest

@testable import VoicePaste

/// Модель раздела истории обязана работать при любом порядке `onAppear` и
/// `.task`: SwiftUI его не гарантирует. 21.09.2026 `.task` на живой машине
/// успел раньше подключения хранилища, и история не появилась вовсе.
@MainActor
final class HistoryListModelTests: XCTestCase {
    private let tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("HistoryListModelTests-\(UUID().uuidString)", isDirectory: true)

    override func setUp() async throws {
        try await super.setUp()
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        try await super.tearDown()
    }

    private func makeStoreWithRecord(id: UUID) async throws -> HistoryStore {
        let pool = try DatabasePool(path: tempDirectory.appendingPathComponent("history.sqlite").path)
        try Migrations.migrator.migrate(pool)
        let store = HistoryStore(dbPool: pool)
        let text = "Запись из плашки"
        try await store.save(Transcript(
            id: id, createdAt: 1_000, updatedAt: 1_000, source: .dictation, sourceFileName: nil,
            durationMilliseconds: 1_000, language: "ru", rawText: text, text: text,
            preview: Transcript.makePreview(from: text), status: .completed, insertionOutcome: .notRequested
        ))
        return store
    }

    private func waitForDetail(_ model: HistoryListModel) async throws {
        for _ in 0..<50 where model.detail == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func test_loadingStartedFirst_fillsTheList() async throws {
        let id = UUID()
        let model = HistoryListModel(store: try await makeStoreWithRecord(id: id))

        let observing = Task { await model.observeChanges() }
        defer { observing.cancel() }
        for _ in 0..<50 where model.items.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(model.items.map(\.id), [id], "загрузка, начатая первой, оставила историю пустой")
    }

    func test_selectionMadeFirst_loadsTheRecord() async throws {
        let id = UUID()
        let model = HistoryListModel(store: try await makeStoreWithRecord(id: id))

        model.selection = id
        try await waitForDetail(model)

        XCTAssertEqual(model.detail?.id, id, "«Открыть в истории» оставило деталь пустой")
    }

    // MARK: - Отзывчивость списка (D1)

    private func makeModel(
        count: Int,
        detailDelay: [UUID: Duration] = [:],
        deleteDelay: Duration = .zero,
        firstPageDelay: Duration = .zero,
        failsDelete: Bool = false
    ) -> (HistoryListModel, FakeHistoryStore) {
        let store = FakeHistoryStore(
            count: count, detailDelay: detailDelay, deleteDelay: deleteDelay,
            firstPageDelay: firstPageDelay, failsDelete: failsDelete
        )
        return (HistoryListModel(store: store), store)
    }

    private func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<150 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// Ждёт, пока хранилище перестанет получать обращения: «после тика» не
    /// означает «после первого запроса тика».
    private func settle(_ store: FakeHistoryStore) async {
        var last = -1
        var calm = 0
        while calm < 5 {
            try? await Task.sleep(for: .milliseconds(30))
            let now = store.pageFetches + store.inFlight * 10_000
            calm = now == last ? calm + 1 : 0
            last = now
        }
    }

    private func loadAll(_ model: HistoryListModel, expecting total: Int) async {
        while model.items.count < total {
            let before = model.items.count
            guard let last = model.items.last else { return }
            model.loadNextPageIfNeeded(current: last)
            _ = await eventually { model.items.count > before }
            if model.items.count == before { return }
        }
    }

    func test_beforeTheFirstPage_listIsNotLoaded_soEmptyStateIsNotShown() async throws {
        let (model, _) = makeModel(count: 3, firstPageDelay: .milliseconds(250))
        XCTAssertFalse(model.isLoaded)

        let observing = Task { await model.observeChanges() }
        defer { observing.cancel() }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(model.isLoaded, "«Нет записей» показали бы, пока первая выборка ещё идёт")

        let loaded = await eventually { model.isLoaded }
        XCTAssertTrue(loaded)
        XCTAssertEqual(model.items.count, 3)
    }

    func test_emptyStore_becomesLoadedWithNoItems() async throws {
        let (model, _) = makeModel(count: 0)
        let observing = Task { await model.observeChanges() }
        defer { observing.cancel() }

        let loaded = await eventually { model.isLoaded }
        XCTAssertTrue(loaded, "пустая база тоже даёт «загружено», иначе «Нет записей» не появится никогда")
        XCTAssertTrue(model.items.isEmpty)
    }

    func test_changeTick_keepsEveryLoadedRow() async throws {
        let (model, store) = makeModel(count: 250)
        let observing = Task { await model.observeChanges() }
        defer { observing.cancel() }
        _ = await eventually { model.items.count == 100 }
        await loadAll(model, expecting: 250)
        XCTAssertEqual(model.items.count, 250)

        store.emitChange()
        await settle(store)

        XCTAssertEqual(model.items.count, 250, "тик обновления схлопнул список до первой страницы")
    }

    func test_nextPage_isRequestedBeforeTheLastRow_andOnlyOnceForRepeatedAppear() async throws {
        let (model, store) = makeModel(count: 250)
        let observing = Task { await model.observeChanges() }
        defer { observing.cancel() }
        _ = await eventually { model.items.count == 100 }
        await settle(store)
        let before = store.pageFetches

        model.loadNextPageIfNeeded(current: model.items[50])
        await settle(store)
        let farFromEnd = store.pageFetches
        XCTAssertEqual(farFromEnd, before, "подгрузка началась далеко от конца списка")

        let nearEnd = model.items[model.items.count - 15]
        model.loadNextPageIfNeeded(current: nearEnd)
        model.loadNextPageIfNeeded(current: nearEnd)
        model.loadNextPageIfNeeded(current: model.items[model.items.count - 1])
        await settle(store)

        let after = store.pageFetches
        XCTAssertEqual(after, before + 1, "повторный onAppear запустил вторую выборку по тому же курсору")
        XCTAssertEqual(model.items.count, 200)
        XCTAssertEqual(Set(model.items.map(\.id)).count, 200, "страница дописана дважды")
    }

    func test_slowAnswerToEarlierSelection_doesNotReplaceTheLaterOne() async throws {
        let first = FakeHistoryStore.recordID(0)
        let second = FakeHistoryStore.recordID(1)
        let (model, store) = makeModel(count: 3, detailDelay: [first: .milliseconds(300)])

        model.selection = first
        model.selection = second
        _ = await eventually { store.completedDetailFetches == 2 }
        await Task.yield()

        XCTAssertEqual(model.detail?.id, second, "поздний ответ на прежний выбор перетёр новый")
    }

    func test_delete_removesTheRowBeforeTheStoreAnswers() async throws {
        let (model, store) = makeModel(count: 3, deleteDelay: .milliseconds(300))
        let observing = Task { await model.observeChanges() }
        defer { observing.cancel() }
        _ = await eventually { model.items.count == 3 }
        let doomed = model.items[1].id

        model.delete(id: doomed)

        XCTAssertFalse(model.items.contains { $0.id == doomed }, "строка ждёт круга базы")
        _ = await eventually { store.deleteCalls == 1 }
    }

    func test_deleteOfSelectedRow_selectsTheNeighbour() async throws {
        let (model, _) = makeModel(count: 3)
        let observing = Task { await model.observeChanges() }
        defer { observing.cancel() }
        _ = await eventually { model.items.count == 3 }
        let ids = model.items.map(\.id)
        model.selection = ids[1]

        model.delete(id: ids[1])

        XCTAssertEqual(model.selection, ids[2])
    }

    func test_refreshWhileDeleteIsPending_doesNotBringTheRowBack() async throws {
        let (model, store) = makeModel(count: 3, deleteDelay: .milliseconds(400))
        let observing = Task { await model.observeChanges() }
        defer { observing.cancel() }
        _ = await eventually { model.items.count == 3 }
        let doomed = model.items[0].id

        model.delete(id: doomed)
        store.emitChange()
        await settle(store)

        XCTAssertFalse(model.items.contains { $0.id == doomed }, "тик вернул удаляемую строку")
    }

    func test_failedDelete_returnsTheRowToItsPlace_andSaysSo() async throws {
        let (model, store) = makeModel(count: 3, failsDelete: true)
        let observing = Task { await model.observeChanges() }
        defer { observing.cancel() }
        _ = await eventually { model.items.count == 3 }
        let ids = model.items.map(\.id)

        model.delete(id: ids[1])
        _ = await eventually { store.deleteCalls == 1 }
        let restored = await eventually { model.items.map(\.id) == ids }

        XCTAssertTrue(restored, "строка не вернулась на прежнее место")
        XCTAssertTrue(model.didFailToDelete, "отказ базы остался незамеченным")
    }

    // MARK: - Отказы видны, а не выдаются за «пусто»

    func test_failedFirstLoad_isFailure_notAnEmptyHistory() async throws {
        let (model, store) = makeModel(count: 3)
        store.failsPages = true

        let observing = Task { await model.observeChanges() }
        defer { observing.cancel() }
        let failed = await eventually { model.didFailToLoad }

        XCTAssertTrue(failed, "сбой выборки показали бы как «Нет записей»")
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(model.isLoaded, "заглушка загрузки не должна висеть вечно")
    }

    func test_retryAfterFailure_loadsTheList_andClearsTheFailure() async throws {
        let (model, store) = makeModel(count: 3)
        store.failsPages = true
        let observing = Task { await model.observeChanges() }
        defer { observing.cancel() }
        _ = await eventually { model.didFailToLoad }

        store.failsPages = false
        await model.retry()

        XCTAssertEqual(model.items.count, 3)
        XCTAssertFalse(model.didFailToLoad)
    }

    func test_failedRefresh_keepsTheRowsAlreadyShown() async throws {
        let (model, store) = makeModel(count: 3)
        let observing = Task { await model.observeChanges() }
        defer { observing.cancel() }
        _ = await eventually { model.items.count == 3 }

        store.failsPages = true
        store.emitChange()
        _ = await eventually { model.didFailToLoad }

        XCTAssertEqual(model.items.count, 3, "сбой обновления стёр список")
    }

    func test_failedDetail_isShown_andClearedByTheNextSelection() async throws {
        let (model, store) = makeModel(count: 3)
        store.failsDetail = true

        model.selection = FakeHistoryStore.recordID(0)
        let failed = await eventually { model.didFailToOpenDetail }
        XCTAssertTrue(failed, "сбой чтения записи выглядел как «Выберите запись»")
        XCTAssertNil(model.detail)

        store.failsDetail = false
        model.selection = FakeHistoryStore.recordID(1)
        let opened = await eventually { model.detail?.id == FakeHistoryStore.recordID(1) }
        XCTAssertTrue(opened)
        XCTAssertFalse(model.didFailToOpenDetail)
    }

    // MARK: - Поиск: задержка не больше самого запроса

    func test_searchDebounce_isShortEnoughToFeelInstant() {
        XCTAssertLessThanOrEqual(
            HistoryListModel.defaultSearchDebounce, .milliseconds(100),
            "запрос к 2,4 тыс. записей — около 2 мс (замер 14.10), а ожидание стоило 250"
        )
    }

    func test_searchBurst_sendsOnlyTheLastQuery() async throws {
        let store = FakeHistoryStore(count: 3)
        let model = HistoryListModel(store: store, searchDebounce: .milliseconds(30))

        model.searchText = "п"
        model.searchText = "пе"
        model.searchText = "пер"
        let sent = await eventually { store.searchQueries.contains("пер") }
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertTrue(sent)
        XCTAssertEqual(store.searchQueries, ["пер"], "устаревший запрос дошёл до хранилища")
    }

    // MARK: - Редактор: просмотр не пишет

    private func makeTranscript(text: String = "Исходный текст") -> Transcript {
        Transcript(
            id: UUID(), createdAt: 1_000, updatedAt: 1_000, source: .dictation, sourceFileName: nil,
            durationMilliseconds: 1_000, language: "ru", rawText: text, text: text,
            preview: Transcript.makePreview(from: text), status: .completed, insertionOutcome: .notRequested
        )
    }

    func test_openingARecord_writesNothing() async throws {
        let store = FakeHistoryStore(count: 0)
        let model = DetailEditModel(
            transcript: makeTranscript(), store: store, debounce: .milliseconds(20), onSaved: { _ in }
        )
        XCTAssertEqual(model.text, "Исходный текст", "текст появляется в первом кадре, а не после .task")

        try await Task.sleep(for: .milliseconds(150))

        let edits = store.editCalls
        XCTAssertTrue(edits.isEmpty, "просмотр записи породил UPDATE: \(edits.count)")
    }

    func test_sameTextTyped_writesNothing() async throws {
        let store = FakeHistoryStore(count: 0)
        let model = DetailEditModel(
            transcript: makeTranscript(), store: store, debounce: .milliseconds(20), onSaved: { _ in }
        )

        model.userEdited("Исходный текст")
        try await Task.sleep(for: .milliseconds(150))

        let edits = store.editCalls
        XCTAssertTrue(edits.isEmpty)
    }

    func test_userEdits_areCoalescedIntoOneWrite_andReported() async throws {
        let store = FakeHistoryStore(count: 0)
        var saved: [Transcript] = []
        let transcript = makeTranscript()
        let model = DetailEditModel(
            transcript: transcript, store: store, debounce: .milliseconds(40), onSaved: { saved.append($0) }
        )

        model.userEdited("Исходный текс")
        model.userEdited("Новый текст")
        let wrote = await eventually { store.editCalls.count == 1 }
        _ = await eventually { saved.count == 1 }

        XCTAssertTrue(wrote)
        let edits = store.editCalls
        XCTAssertEqual(edits.map(\.text), ["Новый текст"])
        XCTAssertEqual(saved.first?.text, "Новый текст")
        XCTAssertEqual(saved.first?.rawText, transcript.rawText, "правка тронула исходное распознавание")
    }

    func test_pendingEdit_survivesTheEditorBeingClosed() async throws {
        let store = FakeHistoryStore(count: 0)
        var model: DetailEditModel? = DetailEditModel(
            transcript: makeTranscript(), store: store, debounce: .milliseconds(40), onSaved: { _ in }
        )
        model?.userEdited("Дописал и сразу ушёл на другую запись")
        model = nil

        let wrote = await eventually { store.editCalls.count == 1 }

        XCTAssertTrue(wrote, "правка потерялась при переходе на другую запись")
    }

    func test_failedSave_isShown_andNotReportedAsSaved() async throws {
        let store = FakeHistoryStore(count: 0, failsEdit: true)
        var saved = 0
        let model = DetailEditModel(
            transcript: makeTranscript(), store: store, debounce: .milliseconds(20), onSaved: { _ in saved += 1 }
        )

        model.userEdited("Другой текст")
        let failed = await eventually { model.didFailToSave }

        XCTAssertTrue(failed)
        XCTAssertEqual(saved, 0)
    }

    // MARK: - Статистика: «пусто» только после загрузки

    func test_usageStats_areLoading_untilTheStoreAnswers() async throws {
        let store = FakeHistoryStore(count: 0, usageDelay: .milliseconds(250))
        let model = UsageStatsModel(store: store)
        XCTAssertFalse(model.isLoaded)

        let tracking = Task { await model.track(dayCount: 30) }
        defer { tracking.cancel() }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(model.isLoaded, "«Здесь появится статистика» мигнуло бы до прихода данных")

        let loaded = await eventually { model.isLoaded }
        XCTAssertTrue(loaded)
        XCTAssertEqual(model.stats.totalWordCount, 5)
    }

    func test_usageStatsFailure_isFailure_notEmptyData() async throws {
        let store = FakeHistoryStore(count: 0, failsUsage: true)
        let model = UsageStatsModel(store: store)

        let tracking = Task { await model.track(dayCount: 30) }
        defer { tracking.cancel() }
        let failed = await eventually { model.didFailToLoad }

        XCTAssertTrue(failed)
        XCTAssertFalse(model.isLoaded)
    }
}

/// Хранилище-пустышка: считает обращения и отвечает с заданной задержкой.
/// Поздний ответ на прежний запрос отменой не обрывается — как у настоящей
/// выборки, которую уже начала база.
@MainActor
final class FakeHistoryStore: HistoryStoring {
    private var records: [Transcript]
    private let detailDelay: [UUID: Duration]
    private let deleteDelay: Duration
    private let firstPageDelay: Duration
    private let usageDelay: Duration
    private let failsDelete: Bool
    private let failsEdit: Bool
    private let failsUsage: Bool
    private nonisolated let broadcaster = ChangeBroadcaster()

    private(set) var pageFetches = 0
    private(set) var inFlight = 0
    private(set) var completedDetailFetches = 0
    private(set) var deleteCalls = 0
    private(set) var editCalls: [(id: UUID, text: String)] = []
    private(set) var searchQueries: [String] = []
    var failsPages = false
    var failsDetail = false

    init(
        count: Int,
        detailDelay: [UUID: Duration] = [:],
        deleteDelay: Duration = .zero,
        firstPageDelay: Duration = .zero,
        usageDelay: Duration = .zero,
        failsDelete: Bool = false,
        failsEdit: Bool = false,
        failsUsage: Bool = false
    ) {
        self.records = (0..<count).map { Self.makeRecord(index: $0) }
        self.detailDelay = detailDelay
        self.deleteDelay = deleteDelay
        self.firstPageDelay = firstPageDelay
        self.usageDelay = usageDelay
        self.failsDelete = failsDelete
        self.failsEdit = failsEdit
        self.failsUsage = failsUsage
    }

    static func recordID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
    }

    private static func makeRecord(index: Int) -> Transcript {
        let text = "Запись \(index)"
        return Transcript(
            id: recordID(index), createdAt: Int64(1_000_000 - index), updatedAt: Int64(1_000_000 - index),
            source: .dictation, sourceFileName: nil, durationMilliseconds: 1_000, language: "ru",
            rawText: text, text: text, preview: Transcript.makePreview(from: text),
            status: .completed, insertionOutcome: .notRequested
        )
    }

    func emitChange() { broadcaster.send() }

    func fetchPage(after cursor: TranscriptCursor?) async throws -> TranscriptPage {
        inFlight += 1
        defer { inFlight -= 1 }
        pageFetches += 1
        if failsPages { throw HistoryError.notFound }
        if cursor == nil, firstPageDelay != .zero { try? await Task.sleep(for: firstPageDelay) }
        let rest = records.filter { record in
            guard let cursor else { return true }
            return record.createdAt < cursor.createdAt
                || (record.createdAt == cursor.createdAt && record.id.uuidString < cursor.id.uuidString)
        }
        let page = Array(rest.prefix(HistoryPaging.pageSize))
        let items = page.map { record in
            TranscriptListItem(
                id: record.id, createdAt: record.createdAt, updatedAt: record.updatedAt, source: record.source,
                sourceFileName: record.sourceFileName, durationMilliseconds: record.durationMilliseconds,
                language: record.language, preview: record.preview, status: record.status,
                insertionOutcome: record.insertionOutcome
            )
        }
        let next = rest.count > page.count
            ? items.last.map { TranscriptCursor(createdAt: $0.createdAt, id: $0.id) }
            : nil
        return TranscriptPage(items: items, nextCursor: next)
    }

    func fetchDetail(id: UUID) async throws -> Transcript {
        if let delay = detailDelay[id] { try? await Task.sleep(for: delay) }
        completedDetailFetches += 1
        if failsDetail { throw HistoryError.notFound }
        guard let record = records.first(where: { $0.id == id }) else { throw HistoryError.notFound }
        return record
    }

    func search(query: String, after cursor: TranscriptCursor?) async throws -> TranscriptPage {
        searchQueries.append(query)
        return TranscriptPage(items: [], nextCursor: nil)
    }

    nonisolated func changes() -> AsyncStream<Void> { broadcaster.stream() }

    func save(_ transcript: Transcript) async throws {
        records.insert(transcript, at: 0)
        broadcaster.send()
    }

    func edit(id: UUID, text: String, updatedAt: Int64) async throws {
        editCalls.append((id, text))
        if failsEdit { throw HistoryError.notFound }
    }

    func delete(id: UUID) async throws {
        deleteCalls += 1
        if deleteDelay != .zero { try? await Task.sleep(for: deleteDelay) }
        if failsDelete { throw HistoryError.notFound }
        records.removeAll { $0.id == id }
        broadcaster.send()
    }

    func clearAll() async throws { records.removeAll() }

    func fetchUsageStats(now: Date, dayCount: Int) async throws -> UsageStats {
        if usageDelay != .zero { try? await Task.sleep(for: usageDelay) }
        if failsUsage { throw HistoryError.notFound }
        return UsageStats(
            dailyStats: [DailyUsageStat(day: now, wordCount: 5, transcriptCount: 1, durationMilliseconds: 1_000)],
            totalWordCount: 5, totalTranscriptCount: 1, totalDurationMilliseconds: 1_000, activeDayCount: 1
        )
    }

    func fetchVocabulary() async throws -> [VocabularyEntry] { [] }
    func upsertVocabulary(_ entry: VocabularyEntry) async throws {}
    func deleteVocabulary(id: UUID) async throws {}
}

/// Рассылает «что-то изменилось» подписчикам; первый сигнал — сразу при
/// подписке, как у настоящего хранилища.
private final class ChangeBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<Void>.Continuation] = []

    func stream() -> AsyncStream<Void> {
        AsyncStream { continuation in
            lock.lock()
            continuations.append(continuation)
            lock.unlock()
            continuation.yield()
        }
    }

    func send() {
        lock.lock()
        let all = continuations
        lock.unlock()
        all.forEach { $0.yield() }
    }
}

