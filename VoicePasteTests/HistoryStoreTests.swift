import GRDB
import XCTest
@testable import VoicePaste

/// Gate 2 integration tests for the real `HistoryStore` actor (`L-008`,
/// `DM-002`/`DM-003`/`DM-004`) against a genuine GRDB `DatabasePool` backed
/// by a temporary on-disk SQLite file (WAL, same `Migrations.migrator` the
/// app uses) — never a mock, never `:memory:` (GRDB's `DatabasePool` needs a
/// real file to support its multi-reader pool).
@MainActor
final class HistoryStoreTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoicePasteTests-HistoryStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try await super.tearDown()
    }

    private var databaseURL: URL {
        tempDirectory.appendingPathComponent("history.sqlite")
    }

    /// Mirrors `AppDatabase.makePool()` exactly (WAL, busy timeout,
    /// `Migrations.migrator`), just pointed at a throwaway temp file so tests
    /// never touch the real `~/Library/Application Support/VoicePaste/`.
    private func makePool() throws -> DatabasePool {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        configuration.busyMode = .timeout(5)
        let pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        try Migrations.migrator.migrate(pool)
        return pool
    }

    private func makeTranscript(
        id: UUID = UUID(),
        createdAt: Int64,
        text: String = "Пример текста",
        sourceFileName: String? = nil,
        source: Transcript.Source = .dictation
    ) -> Transcript {
        Transcript(
            id: id,
            createdAt: createdAt,
            updatedAt: createdAt,
            source: source,
            sourceFileName: sourceFileName,
            durationMilliseconds: 1_000,
            language: "ru",
            rawText: text,
            text: text,
            preview: Transcript.makePreview(from: text),
            status: .completed,
            insertionOutcome: .notRequested
        )
    }

    // MARK: - AT-017: save, "restart" (reopen the same file), still there

    func test_AT017_savedTranscript_survivesReopeningTheDatabase() async throws {
        let id = UUID()
        do {
            let pool = try makePool()
            let store = HistoryStore(dbPool: pool)
            try await store.save(makeTranscript(id: id, createdAt: 1, text: "Привет из первой сессии"))
        }

        // Simulates an app restart: fresh pool/migrator over the same file.
        let reopenedPool = try makePool()
        let reopenedStore = HistoryStore(dbPool: reopenedPool)

        let detail = try await reopenedStore.fetchDetail(id: id)
        XCTAssertEqual(detail.text, "Привет из первой сессии")
        XCTAssertEqual(detail.durationMilliseconds, 1_000)
        XCTAssertEqual(detail.insertionOutcome, .notRequested)

        let page = try await reopenedStore.fetchPage(after: nil)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items[0].id, id)
    }

    /// `L-008`: history disabled -> nothing gets saved.
    func test_historyDisabled_saveThrows_andNoRowIsCreated() async throws {
        let pool = try makePool()
        let store = HistoryStore(dbPool: pool, historyEnabled: { false })
        let id = UUID()

        do {
            try await store.save(makeTranscript(id: id, createdAt: 1))
            XCTFail("Expected HistoryError.historyDisabled")
        } catch HistoryError.historyDisabled {
            // expected
        }

        let enabledStore = HistoryStore(dbPool: pool, historyEnabled: { true })
        let page = try await enabledStore.fetchPage(after: nil)
        XCTAssertTrue(page.items.isEmpty)
    }

    // MARK: - AT-018: edit preserves rawText, updates text/preview/updatedAt

    func test_AT018_edit_changesTextAndPreview_butPreservesRawText() async throws {
        let pool = try makePool()
        let store = HistoryStore(dbPool: pool)
        let id = UUID()
        try await store.save(makeTranscript(id: id, createdAt: 1, text: "исходный текст, оригинал модели"))

        try await store.edit(id: id, text: "отредактированный текст", updatedAt: 2)

        let detail = try await store.fetchDetail(id: id)
        XCTAssertEqual(detail.text, "отредактированный текст")
        XCTAssertEqual(detail.preview, Transcript.makePreview(from: "отредактированный текст"))
        XCTAssertEqual(detail.updatedAt, 2)
        XCTAssertEqual(detail.rawText, "исходный текст, оригинал модели", "L-008: rawText must never change on edit.")
    }

    func test_edit_unknownId_throwsNotFound() async throws {
        let pool = try makePool()
        let store = HistoryStore(dbPool: pool)

        do {
            try await store.edit(id: UUID(), text: "x", updatedAt: 1)
            XCTFail("Expected HistoryError.notFound")
        } catch HistoryError.notFound {
            // expected
        }
    }

    // MARK: - AT-019/AT-030: FTS5 search over text and sourceFileName

    func test_AT019_search_findsByTextPhrase() async throws {
        let pool = try makePool()
        let store = HistoryStore(dbPool: pool)
        try await store.save(makeTranscript(createdAt: 1, text: "Купить молоко и хлеб"))
        try await store.save(makeTranscript(createdAt: 2, text: "Позвонить маме вечером"))

        let page = try await store.search(query: "молоко", after: nil)

        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items[0].preview, "Купить молоко и хлеб")
    }

    func test_AT019_AT030_search_findsByPartialSourceFileName() async throws {
        let pool = try makePool()
        let store = HistoryStore(dbPool: pool)
        try await store.save(makeTranscript(
            createdAt: 1,
            text: "Расшифровка голосового",
            sourceFileName: "telegram-voice-2026-07-19.ogg",
            source: .file
        ))
        try await store.save(makeTranscript(createdAt: 2, text: "Другая запись", source: .dictation))

        let page = try await store.search(query: "telegram", after: nil)

        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items[0].sourceFileName, "telegram-voice-2026-07-19.ogg")
    }

    func test_search_neverThrowsOnArbitraryUserInput() async throws {
        let pool = try makePool()
        let store = HistoryStore(dbPool: pool)
        try await store.save(makeTranscript(createdAt: 1, text: "обычный текст"))

        // Characters that are special to raw FTS5 MATCH syntax must not
        // crash `search` (the implementation escapes via
        // `FTS5Pattern(matchingAllPrefixesIn:)`).
        for query in ["\"", "*", "AND OR NOT", "()", ""] {
            let page = try await store.search(query: query, after: nil)
            XCTAssertNotNil(page.items) // did not throw
        }
    }

    // MARK: - AT-020: delete / clearAll

    func test_AT020_delete_removesOnlyThatRow() async throws {
        let pool = try makePool()
        let store = HistoryStore(dbPool: pool)
        let keepId = UUID()
        let deleteId = UUID()
        try await store.save(makeTranscript(id: keepId, createdAt: 1, text: "оставить"))
        try await store.save(makeTranscript(id: deleteId, createdAt: 2, text: "удалить"))

        try await store.delete(id: deleteId)

        let page = try await store.fetchPage(after: nil)
        XCTAssertEqual(page.items.map(\.id), [keepId])
        do {
            _ = try await store.fetchDetail(id: deleteId)
            XCTFail("Expected notFound after delete")
        } catch HistoryError.notFound {
            // expected
        }
    }

    func test_delete_unknownId_throwsNotFound() async throws {
        let pool = try makePool()
        let store = HistoryStore(dbPool: pool)

        do {
            try await store.delete(id: UUID())
            XCTFail("Expected HistoryError.notFound")
        } catch HistoryError.notFound {
            // expected
        }
    }

    func test_AT020_clearAll_removesEverything_includingFTSIndex() async throws {
        let pool = try makePool()
        let store = HistoryStore(dbPool: pool)
        try await store.save(makeTranscript(createdAt: 1, text: "первая запись"))
        try await store.save(makeTranscript(createdAt: 2, text: "вторая запись"))

        try await store.clearAll()

        let page = try await store.fetchPage(after: nil)
        XCTAssertTrue(page.items.isEmpty)
        // The FTS index must be empty too, not just the base table (AT-031's
        // "no row without its FTS counterpart" invariant, checked from the
        // other direction here: no orphaned FTS rows either).
        let searchAfterClear = try await store.search(query: "запись", after: nil)
        XCTAssertTrue(searchAfterClear.items.isEmpty)
    }

    // MARK: - AT-029/AT-034: 10k-row scale, keyset pagination, page size 100

    func test_AT029_pagination_returnsExactly100PerPage_newestFirst_neverReadingFullText() async throws {
        let pool = try makePool()
        let store = HistoryStore(dbPool: pool)

        // Bulk-insert 10,000 rows directly for speed; still exercises the
        // exact same schema/indexes/triggers `save()` writes through. Built
        // from plain values (not `self.makeTranscript`) since `pool.write`'s
        // closure is `@Sendable` and this test case itself is not `Sendable`.
        try await pool.write { db in
            for i in 0..<10_000 {
                let text = "Запись номер \(i)"
                let transcript = Transcript(
                    id: UUID(),
                    createdAt: Int64(i),
                    updatedAt: Int64(i),
                    source: .dictation,
                    sourceFileName: nil,
                    durationMilliseconds: 1_000,
                    language: "ru",
                    rawText: text,
                    text: text,
                    preview: Transcript.makePreview(from: text),
                    status: .completed,
                    insertionOutcome: .notRequested
                )
                try transcript.insert(db)
            }
        }

        let firstPage = try await store.fetchPage(after: nil)

        XCTAssertEqual(firstPage.items.count, HistoryPaging.pageSize)
        XCTAssertEqual(HistoryPaging.pageSize, 100)
        // Newest first: createdAt 9999 down to 9900.
        XCTAssertEqual(firstPage.items.first?.createdAt, 9_999)
        XCTAssertEqual(firstPage.items.last?.createdAt, 9_900)
        XCTAssertNotNil(firstPage.nextCursor)

        guard let cursor = firstPage.nextCursor else { return XCTFail("Expected a next cursor for 10k rows") }
        let secondPage = try await store.fetchPage(after: cursor)
        XCTAssertEqual(secondPage.items.count, HistoryPaging.pageSize)
        XCTAssertEqual(secondPage.items.first?.createdAt, 9_899)

        // No overlap between pages (stable keyset pagination, no OFFSET drift).
        let firstIds = Set(firstPage.items.map(\.id))
        let secondIds = Set(secondPage.items.map(\.id))
        XCTAssertTrue(firstIds.isDisjoint(with: secondIds))
    }

    /// `TranscriptListItem` (what `fetchPage`/`search` return) has no
    /// `rawText`/`text` property at all — the compiler itself enforces that
    /// list pages can never carry full text, matching `AT-029`'s "полные
    /// тексты не читаются до выбора" at the type level.
    func test_listItemType_hasNoFullTextFields_byConstruction() {
        let mirror = Mirror(reflecting: TranscriptListItem(
            id: UUID(), createdAt: 0, updatedAt: 0, source: .dictation, sourceFileName: nil,
            durationMilliseconds: 0, language: nil, preview: "x", status: .completed, insertionOutcome: .notRequested
        ))
        let labels = Set(mirror.children.compactMap(\.label))
        XCTAssertFalse(labels.contains("text"))
        XCTAssertFalse(labels.contains("rawText"))
        XCTAssertTrue(labels.contains("preview"))
    }

    func test_AT030_search_worksAcrossLargeDataset_andPaginates() async throws {
        let pool = try makePool()
        let store = HistoryStore(dbPool: pool)

        try await pool.write { db in
            for i in 0..<10_000 {
                let text = i == 4_242 ? "уникальнаяредкаяфразадлятеста" : "обычная запись номер \(i)"
                let transcript = Transcript(
                    id: UUID(),
                    createdAt: Int64(i),
                    updatedAt: Int64(i),
                    source: .dictation,
                    sourceFileName: nil,
                    durationMilliseconds: 1_000,
                    language: "ru",
                    rawText: text,
                    text: text,
                    preview: Transcript.makePreview(from: text),
                    status: .completed,
                    insertionOutcome: .notRequested
                )
                try transcript.insert(db)
            }
        }

        let page = try await store.search(query: "уникальнаяредкаяфразадлятеста", after: nil)

        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items[0].createdAt, 4_242)
        XCTAssertNil(page.nextCursor)
    }

    // MARK: - AT-031: no row without preview/FTS index (transactional save)

    func test_AT031_everySavedRow_hasNonEmptyPreview_andIsFindableViaFTS() async throws {
        let pool = try makePool()
        let store = HistoryStore(dbPool: pool)
        let id = UUID()
        try await store.save(makeTranscript(id: id, createdAt: 1, text: "проверка целостности записи"))

        let detail = try await store.fetchDetail(id: id)
        XCTAssertFalse(detail.preview.isEmpty)

        let found = try await store.search(query: "целостности", after: nil)
        XCTAssertEqual(found.items.map(\.id), [id])
    }

    // MARK: - AT-032: migration safety (gap noted — see final report)

    /// There is currently exactly one migration (`v1_initial_schema`); no
    /// fixture of a *previous* supported schema exists yet to actually
    /// replay `AT-032` end-to-end. This test instead locks in the two safety
    /// properties `Migrations.swift`'s own doc comments promise, so a
    /// regression here fails loudly the moment they're violated:
    /// - the migrator never erases the database on a schema mismatch;
    /// - migrating an already-migrated pool a second time is a no-op, not a
    ///   destructive re-run (forward-compatible for when migration 2 ships).
    func test_AT032_migratorNeverErasesOnSchemaChange_andIsIdempotent() async throws {
        XCTAssertFalse(Migrations.migrator.eraseDatabaseOnSchemaChange)

        let pool = try makePool()
        let store = HistoryStore(dbPool: pool)
        try await store.save(makeTranscript(createdAt: 1, text: "переживает миграцию"))

        // Re-running migrate() against the same, already-migrated pool must
        // not drop existing data.
        try Migrations.migrator.migrate(pool)

        let page = try await store.fetchPage(after: nil)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items[0].preview, "переживает миграцию")
    }

    // MARK: - AT-038: durable FIFO import queue

    func test_AT038_importQueuePersistsFIFO_andSafelyRequeuesInterruptedWork() async throws {
        let queue = ImportQueueStore(dbPool: try makePool())
        let first = ImportJob(
            fileName: "lecture.mp4", createdAt: 1, mediaKind: .video,
            state: .transcribing, progress: 0.62
        )
        let second = ImportJob(
            fileName: "voice.ogg", createdAt: 2, mediaKind: .audio,
            state: .failed, failureKey: "import.error.decodeFailed"
        )
        try await queue.upsert(first)
        try await queue.upsert(second)

        let restored = try await queue.restoreJobs()

        XCTAssertEqual(restored.map(\.id), [first.id, second.id])
        XCTAssertEqual(restored[0].state, .queued)
        XCTAssertEqual(restored[0].progress, 0)
        XCTAssertEqual(restored[1].state, .failed)
        XCTAssertEqual(restored[1].failureKey, "import.error.decodeFailed")
    }

    // MARK: - AT-036: usage dashboard aggregation (DM-006/UI-007)

    func test_AT036_fetchUsageStats_groupsWordsByDay_andSummaryTotalsMatch() async throws {
        let pool = try makePool()
        let store = HistoryStore(dbPool: pool)

        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else {
            return XCTFail("Could not compute yesterday")
        }

        // Two transcripts today (3 + 2 words), one yesterday (4 words).
        try await store.save(makeTranscript(
            createdAt: Int64(today.timeIntervalSince1970 * 1_000) + 1_000,
            text: "три слова тут"
        ))
        try await store.save(makeTranscript(
            createdAt: Int64(today.timeIntervalSince1970 * 1_000) + 2_000,
            text: "два слова"
        ))
        try await store.save(makeTranscript(
            createdAt: Int64(yesterday.timeIntervalSince1970 * 1_000) + 1_000,
            text: "четыре разных слова тут"
        ))

        let stats = try await store.fetchUsageStats(now: now, dayCount: 30)

        XCTAssertEqual(stats.dailyStats.count, 30)
        guard let todayStat = stats.dailyStats.first(where: { calendar.isDate($0.day, inSameDayAs: today) }) else {
            return XCTFail("Expected today's bucket in the 30-day window")
        }
        guard let yesterdayStat = stats.dailyStats.first(where: { calendar.isDate($0.day, inSameDayAs: yesterday) }) else {
            return XCTFail("Expected yesterday's bucket in the 30-day window")
        }
        XCTAssertEqual(todayStat.wordCount, 5)
        XCTAssertEqual(todayStat.transcriptCount, 2)
        XCTAssertEqual(todayStat.durationMilliseconds, 2_000)
        XCTAssertEqual(yesterdayStat.wordCount, 4)
        XCTAssertEqual(yesterdayStat.transcriptCount, 1)
        XCTAssertEqual(yesterdayStat.durationMilliseconds, 1_000)

        // Every other day in the window is zero-filled, not simply absent.
        let otherDays = stats.dailyStats.filter {
            !calendar.isDate($0.day, inSameDayAs: today) && !calendar.isDate($0.day, inSameDayAs: yesterday)
        }
        XCTAssertTrue(otherDays.allSatisfy { $0.wordCount == 0 && $0.transcriptCount == 0 && $0.durationMilliseconds == 0 })

        // Summary totals are exactly the sum of the plotted daily bars.
        XCTAssertEqual(stats.totalWordCount, 9)
        XCTAssertEqual(stats.totalTranscriptCount, 3)
        XCTAssertEqual(stats.totalDurationMilliseconds, 3_000)
        XCTAssertEqual(stats.activeDayCount, 2)
    }

    func test_fetchUsageStats_emptyHistory_returnsZeroFilledWindow() async throws {
        let pool = try makePool()
        let store = HistoryStore(dbPool: pool)

        let stats = try await store.fetchUsageStats(now: Date(), dayCount: 30)

        XCTAssertEqual(stats.dailyStats.count, 30)
        XCTAssertTrue(stats.dailyStats.allSatisfy { $0.wordCount == 0 && $0.transcriptCount == 0 && $0.durationMilliseconds == 0 })
        XCTAssertEqual(stats.totalWordCount, 0)
        XCTAssertEqual(stats.totalTranscriptCount, 0)
        XCTAssertEqual(stats.totalDurationMilliseconds, 0)
        XCTAssertEqual(stats.activeDayCount, 0)
    }

    // MARK: - AT-037: wordCount migration + backfill (DM-006)

    func test_AT037_migration_addsWordCountColumn_andBackfillsExistingRows() async throws {
        // Deliberately not `makePool()` (which runs the *full* migrator):
        // this test needs a pool migrated only as far as `v1_initial_schema`,
        // to simulate "a database created before wordCount existed" and then
        // insert rows through raw SQL using exactly the v1 column set (no
        // `wordCount` at all yet) — mirroring a pre-DM-006 `history.sqlite`.
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        configuration.busyMode = .timeout(5)
        let pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        try Migrations.migrator.migrate(pool, upTo: "v1_initial_schema")

        let firstId = UUID().uuidString
        let secondId = UUID().uuidString
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO transcripts (
                        id, createdAt, updatedAt, source, sourceFileName,
                        durationMilliseconds, language, rawText, text, preview,
                        status, insertionOutcome
                    ) VALUES (?, 1, 1, 'dictation', NULL, 1000, 'ru', ?, ?, ?, 'completed', 'notRequested')
                    """,
                arguments: [firstId, "старый текст без счётчика", "старый текст без счётчика", "старый текст без счётчика"]
            )
            try db.execute(
                sql: """
                    INSERT INTO transcripts (
                        id, createdAt, updatedAt, source, sourceFileName,
                        durationMilliseconds, language, rawText, text, preview,
                        status, insertionOutcome
                    ) VALUES (?, 2, 2, 'dictation', NULL, 1000, 'ru', ?, ?, ?, 'completed', 'notRequested')
                    """,
                arguments: [secondId, "два", "два", "два"]
            )
        }

        // Now apply the rest of the migrator (the `v2_transcripts_word_count`
        // migration this task adds) against that pre-existing data.
        try Migrations.migrator.migrate(pool)

        let rows = try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, wordCount FROM transcripts ORDER BY createdAt")
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["id"] as String, firstId)
        XCTAssertEqual(rows[0]["wordCount"] as Int, 4)
        XCTAssertEqual(rows[1]["id"] as String, secondId)
        XCTAssertEqual(rows[1]["wordCount"] as Int, 1)

        // The store built on top of the now-migrated pool sees a coherent
        // aggregate too, not just correct raw columns.
        let store = HistoryStore(dbPool: pool)
        let stats = try await store.fetchUsageStats(now: Date(timeIntervalSince1970: 0.002), dayCount: 30)
        XCTAssertEqual(stats.totalWordCount, 5)
        XCTAssertEqual(stats.totalTranscriptCount, 2)
    }

    // MARK: - Vocabulary (DM-004, feeds AT-016 at the persistence layer)

    func test_vocabulary_upsertFetchDelete_roundTrips() async throws {
        let pool = try makePool()
        let store = HistoryStore(dbPool: pool)
        let entry = VocabularyEntry(
            id: UUID(), spokenForm: "кодекс", replacement: "Codex", isEnabled: true, createdAt: 1, updatedAt: 1
        )

        try await store.upsertVocabulary(entry)
        var fetched = try await store.fetchVocabulary()
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.spokenForm, "кодекс")

        var disabled = entry
        disabled.isEnabled = false
        try await store.upsertVocabulary(disabled)
        fetched = try await store.fetchVocabulary()
        XCTAssertEqual(fetched.count, 1, "upsert by id must update, not duplicate")
        XCTAssertEqual(fetched.first?.isEnabled, false)

        try await store.deleteVocabulary(id: entry.id)
        fetched = try await store.fetchVocabulary()
        XCTAssertTrue(fetched.isEmpty)
    }
}
