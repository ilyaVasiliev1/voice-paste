import Foundation
import GRDB

/// Concrete `HistoryStoring` over a GRDB `DatabasePool` (`L-008`).
///
/// Every method runs the underlying SQLite access through `DatabasePool`'s
/// async `read`/`write` (never the synchronous variants), so the actor never
/// blocks its executor on file I/O: reads happen on GRDB's concurrent reader
/// pool (WAL), and writes are serialized both by this `actor` and by
/// `DatabasePool`'s single writer connection (`L-008`).
///
/// `DatabasePool.write` wraps every call in a SQLite transaction (see
/// `DatabaseWriter.write` docs): combined with the `transcripts_fts`
/// synchronization triggers registered in `Migrations.swift`, a single
/// `write` block that touches `transcripts` therefore also updates
/// `transcripts_fts` atomically — `save`/`edit`/`delete`/`clearAll` never
/// leave a row without its FTS counterpart (`AT-031`).
public actor HistoryStore: HistoryStoring {
    // `nonisolated`: `changes()` (below) must read this from outside the
    // actor's isolation, without an `await` hop, to hand it straight to
    // GRDB's `ValueObservation.values(in:)`. Safe because `DatabasePool`
    // itself is `Sendable` and this is a `let` set once at `init`.
    private nonisolated let dbPool: DatabasePool
    private let historyEnabled: @Sendable () -> Bool

    /// Lightweight sidebar columns, in `TranscriptListItem.init(row:)` order.
    /// Never includes `rawText`/`text` (`data-model.md` "Загрузка истории").
    private nonisolated static let listColumns = [
        "id", "createdAt", "updatedAt", "source", "sourceFileName",
        "durationMilliseconds", "language", "preview", "status", "insertionOutcome",
    ]

    public init(dbPool: DatabasePool, historyEnabled: @escaping @Sendable () -> Bool = { true }) {
        self.dbPool = dbPool
        self.historyEnabled = historyEnabled
    }

    // MARK: - Reading (keyset pagination, DM-002/DM-003 "Загрузка истории")

    public func fetchPage(after cursor: TranscriptCursor?) async throws -> TranscriptPage {
        try await dbPool.read { db in
            try Self.keysetPage(
                db: db,
                fromClause: "transcripts t",
                matchArgument: nil,
                cursor: cursor
            )
        }
    }

    public func fetchDetail(id: UUID) async throws -> Transcript {
        try await dbPool.read { db in
            guard let transcript = try Transcript.fetchOne(
                db,
                sql: "SELECT * FROM transcripts WHERE id = ?",
                arguments: [id.uuidString]
            ) else {
                throw HistoryError.notFound
            }
            return transcript
        }
    }

    public func search(query: String, after cursor: TranscriptCursor?) async throws -> TranscriptPage {
        // Prefix-matches every token in `query` (e.g. a partial file name or
        // a few words of a phrase both resolve, per `AT-019`/`AT-030`), and
        // never throws on arbitrary user input (unlike a raw FTS5 pattern).
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else {
            return TranscriptPage(items: [], nextCursor: nil)
        }
        return try await dbPool.read { db in
            try Self.keysetPage(
                db: db,
                // `transcripts_fts` must be referenced by its own name in the
                // `MATCH` clause, not an alias — SQLite rejects
                // `aliasName MATCH ?` with "no such column".
                fromClause: """
                    transcripts t \
                    JOIN transcripts_fts ON transcripts_fts.rowid = t.rowid AND transcripts_fts MATCH ?
                    """,
                matchArgument: pattern,
                cursor: cursor
            )
        }
    }

    /// Shared keyset-pagination query for `fetchPage`/`search`: same
    /// `createdAt DESC, id DESC` order, same `HistoryPaging.pageSize` cap,
    /// no `OFFSET` (`data-model.md`).
    ///
    /// `nonisolated`: called from inside `dbPool.read`'s `@Sendable`
    /// closure, which runs off `MainActor` (the module's default actor
    /// isolation would otherwise apply here too).
    private nonisolated static func keysetPage(
        db: Database,
        fromClause: String,
        matchArgument: FTS5Pattern?,
        cursor: TranscriptCursor?
    ) throws -> TranscriptPage {
        var arguments: [any DatabaseValueConvertible] = []
        if let matchArgument {
            arguments.append(matchArgument)
        }

        var sql = "SELECT \(listColumns.map { "t.\($0)" }.joined(separator: ", ")) FROM \(fromClause)"
        if let cursor {
            sql += " WHERE (t.createdAt < ? OR (t.createdAt = ? AND t.id < ?))"
            arguments.append(cursor.createdAt)
            arguments.append(cursor.createdAt)
            arguments.append(cursor.id.uuidString)
        }
        sql += " ORDER BY t.createdAt DESC, t.id DESC LIMIT ?"
        // Fetch one extra row to know whether another page follows, without
        // ever using OFFSET.
        arguments.append(HistoryPaging.pageSize + 1)

        let rows = try TranscriptListItem.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        let hasMore = rows.count > HistoryPaging.pageSize
        let items = hasMore ? Array(rows.prefix(HistoryPaging.pageSize)) : rows
        let nextCursor = hasMore
            ? items.last.map { TranscriptCursor(createdAt: $0.createdAt, id: $0.id) }
            : nil
        return TranscriptPage(items: items, nextCursor: nextCursor)
    }

    /// Bug fix (history list staying empty/stale in the long-lived
    /// `HistoryView` window): a `ValueObservation` tracking an aggregate
    /// (`COUNT(*)` + `MAX(updatedAt)`) over `transcripts`. That aggregate
    /// changes on every `save`/`edit`/`delete`/`clearAll`, and GRDB only
    /// re-fetches/emits when the tracked value actually differs from the
    /// last one — so this is a cheap, correct "something changed" signal
    /// without ever copying whole rows across the actor boundary. Scheduled
    /// on GRDB's default `.task` scheduler (values arrive off the main
    /// actor); consumers `await` the stream from wherever suits them.
    public nonisolated func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            // GRDB's `Row` is deliberately `Sendable`-unavailable (rows can
            // wrap a live, non-thread-safe statement), so the tracked value
            // is a small local `Sendable` struct instead of a `Row`. Both
            // scalar queries run inside the same tracking closure, so GRDB's
            // region tracking covers both together.
            struct ChangeFingerprint: Equatable, Sendable {
                let count: Int64
                let maxUpdatedAt: Int64
            }
            let observation = ValueObservation.tracking { db -> ChangeFingerprint in
                let count = try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM transcripts") ?? 0
                let maxUpdatedAt = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(updatedAt), 0) FROM transcripts") ?? 0
                return ChangeFingerprint(count: count, maxUpdatedAt: maxUpdatedAt)
            }
            let task = Task {
                do {
                    for try await _ in observation.values(in: dbPool) {
                        continuation.yield(())
                    }
                } catch {
                    // A failing observation (e.g. the pool closing) simply
                    // ends live-refresh; explicit `fetchPage`/`search` calls
                    // are unaffected.
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Writing (L-008: one transaction per operation)

    public func save(_ transcript: Transcript) async throws {
        guard historyEnabled() else { throw HistoryError.historyDisabled }
        try await dbPool.write { db in
            // Insert alone is enough: the `transcripts_fts` synchronization
            // trigger (DM-003) updates the FTS index in the same
            // transaction, and `preview` already arrived precomputed on
            // `transcript` (DM-002).
            try transcript.insert(db)
        }
    }

    public func edit(id: UUID, text: String, updatedAt: Int64) async throws {
        try await dbPool.write { db in
            let preview = Transcript.makePreview(from: text)
            try db.execute(
                sql: """
                    UPDATE transcripts
                    SET text = ?, preview = ?, updatedAt = ?, wordCount = ?
                    WHERE id = ?
                    """,
                // `DM-006`: recomputed from the edited `text` — this path
                // never routes through `Transcript.encode(to:)`, so
                // `wordCount` must be kept in sync here explicitly.
                arguments: [text, preview, updatedAt, WordCounting.count(in: text), id.uuidString]
            )
            guard db.changesCount > 0 else { throw HistoryError.notFound }
            // `rawText` is intentionally untouched (`L-008`/`DM-002`); the
            // FTS row is refreshed by the same synchronization trigger that
            // fires on this `UPDATE`.
        }
    }

    public func delete(id: UUID) async throws {
        try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM transcripts WHERE id = ?", arguments: [id.uuidString])
            guard db.changesCount > 0 else { throw HistoryError.notFound }
        }
    }

    public func clearAll() async throws {
        try await dbPool.write { db in
            // The synchronization trigger fires per deleted row even for a
            // WHERE-less bulk delete, so `transcripts_fts` ends up empty too,
            // inside this single confirmed transaction (`data-model.md`).
            try db.execute(sql: "DELETE FROM transcripts")
        }
    }

    // MARK: - Statistics

    private struct UsageRow: Sendable {
        let createdAt: Int64
        let wordCount: Int
        let durationMilliseconds: Int
    }

    public func fetchUsageStats(now: Date, dayCount: Int) async throws -> UsageStats {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: now)
        let usesHourlyBuckets = dayCount == 1
        guard dayCount > 0,
              let firstBucket = usesHourlyBuckets
                ? today
                : calendar.date(byAdding: .day, value: -(dayCount - 1), to: today) else {
            return .empty
        }
        let bucketCount = usesHourlyBuckets ? 24 : dayCount
        let bucketComponent: Calendar.Component = usesHourlyBuckets ? .hour : .day
        let startMillis = Int64(firstBucket.timeIntervalSince1970 * 1_000)
        let rows = try await dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT createdAt, wordCount, durationMilliseconds FROM transcripts WHERE createdAt >= ?",
                arguments: [startMillis]
            ).map {
                UsageRow(
                    createdAt: $0["createdAt"], wordCount: $0["wordCount"],
                    durationMilliseconds: $0["durationMilliseconds"]
                )
            }
        }

        var words: [Date: Int] = [:]
        var counts: [Date: Int] = [:]
        var durations: [Date: Int] = [:]
        var buckets: [Date] = []
        for offset in 0..<bucketCount {
            guard let bucket = calendar.date(byAdding: bucketComponent, value: offset, to: firstBucket) else { continue }
            buckets.append(bucket)
            words[bucket] = 0
            counts[bucket] = 0
            durations[bucket] = 0
        }
        for row in rows {
            let date = Date(timeIntervalSince1970: Double(row.createdAt) / 1_000)
            let bucket: Date
            if usesHourlyBuckets {
                bucket = calendar.date(
                    bySettingHour: calendar.component(.hour, from: date),
                    minute: 0,
                    second: 0,
                    of: date
                ) ?? calendar.startOfDay(for: date)
            } else {
                bucket = calendar.startOfDay(for: date)
            }
            words[bucket, default: 0] += row.wordCount
            counts[bucket, default: 0] += 1
            durations[bucket, default: 0] += row.durationMilliseconds
        }
        let dailyStats = buckets.map {
            DailyUsageStat(
                day: $0,
                wordCount: words[$0] ?? 0,
                transcriptCount: counts[$0] ?? 0,
                durationMilliseconds: durations[$0] ?? 0
            )
        }
        let totalWords = dailyStats.reduce(0) { $0 + $1.wordCount }
        let totalTranscripts = dailyStats.reduce(0) { $0 + $1.transcriptCount }
        let totalDuration = dailyStats.reduce(0) { $0 + $1.durationMilliseconds }
        return UsageStats(
            dailyStats: dailyStats,
            totalWordCount: totalWords,
            totalTranscriptCount: totalTranscripts,
            totalDurationMilliseconds: totalDuration,
            activeDayCount: dailyStats.filter { $0.transcriptCount > 0 }.count
        )
    }

    // MARK: - Vocabulary (DM-004)

    public func fetchVocabulary() async throws -> [VocabularyEntry] {
        try await dbPool.read { db in
            try VocabularyEntry.fetchAll(db, sql: "SELECT * FROM vocabulary_entries ORDER BY createdAt")
        }
    }

    public func upsertVocabulary(_ entry: VocabularyEntry) async throws {
        try await dbPool.write { db in
            // `save` updates the row when `id` already exists, inserts
            // otherwise — matches `spokenForm`/`replacement` edits as well as
            // brand-new entries through the same call.
            try entry.save(db)
        }
    }

    public func deleteVocabulary(id: UUID) async throws {
        try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM vocabulary_entries WHERE id = ?", arguments: [id.uuidString])
        }
    }
}
