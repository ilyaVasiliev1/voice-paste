import Foundation
import GRDB

/// Schema migrations for `history.sqlite` (`DM-002` transcripts, `DM-003`
/// transcripts_fts FTS5 + sync triggers, `DM-004` vocabulary_entries).
///
/// Migrations are strictly additive/forward-only (Parallel Change): each
/// future schema change must be registered as a *new* migration appended
/// below, never by editing `v1_initial_schema` once it has shipped. This is
/// what makes `AT-032` (opening a fixture of a previous schema must migrate
/// without losing texts/vocabulary) hold for every future release.
///
/// `DatabaseMigrator.eraseDatabaseOnSchemaChange` is intentionally left at
/// its default `false`: VoicePaste must never silently drop/recreate the
/// user's history because a migration definition changed shape.
public enum Migrations {
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial_schema") { db in
            // DM-002: `transcripts`.
            try db.create(table: "transcripts") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("createdAt", .integer).notNull()
                t.column("updatedAt", .integer).notNull()
                t.column("source", .text).notNull()
                t.column("sourceFileName", .text)
                t.column("durationMilliseconds", .integer).notNull()
                t.column("language", .text)
                t.column("rawText", .text).notNull()
                t.column("text", .text).notNull()
                t.column("preview", .text).notNull()
                t.column("status", .text).notNull()
                t.column("insertionOutcome", .text).notNull()
            }

            // Stable keyset-pagination index: `createdAt DESC, id DESC`
            // (`DM-002`, "Загрузка истории"). GRDB's `create(index:on:columns:)`
            // has no per-column ASC/DESC option, so this uses raw SQL to match
            // the exact sort order `fetchPage`/`search` query with.
            try db.execute(sql: """
                CREATE INDEX transcripts_on_createdAt_id \
                ON transcripts (createdAt DESC, id DESC)
                """)

            // DM-003: `transcripts_fts`, external-content FTS5 table over
            // `text` and `sourceFileName`, synchronized with `transcripts` by
            // GRDB-generated INSERT/UPDATE/DELETE triggers
            // (`synchronize(withTable:)`). It stores no content of its own
            // beyond what `transcripts` already holds locally.
            try db.create(virtualTable: "transcripts_fts", using: FTS5()) { t in
                t.synchronize(withTable: "transcripts")
                t.tokenizer = .unicode61()
                t.column("text")
                t.column("sourceFileName")
            }

            // DM-004: `vocabulary_entries`. `spokenForm` is matched
            // case-insensitively (`DM-004`), but deliberately NOT via SQLite's
            // built-in `NOCASE` collation: `NOCASE` only folds ASCII, so it
            // would silently fail to match "Кодекс"/"кодекс" (the primary
            // Russian use case here). `HistoryStore.fetchVocabulary()` loads
            // the whole (small) table and the case-insensitive comparison is
            // done on the Swift side with Unicode-aware `String` comparison,
            // so no SQL-level collation is needed for correctness.
            try db.create(table: "vocabulary_entries") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("spokenForm", .text).notNull()
                t.column("replacement", .text)
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .integer).notNull()
                t.column("updatedAt", .integer).notNull()
            }
        }

        // DM-006: statistics dashboard (`UI-007`/`US-009`) needs a per-row
        // word count without ever loading full `text` at aggregation time.
        // Forward-only, additive migration (see the type doc comment above):
        // adds `wordCount` to the already-shipped `v1_initial_schema` table
        // instead of editing it, then backfills every existing row so
        // `AT-037` ("открытие базы со старыми строками без wordCount")
        // holds for databases created before this migration existed.
        migrator.registerMigration("v2_transcripts_word_count") { db in
            try db.alter(table: "transcripts") { t in
                t.add(column: "wordCount", .integer).notNull().defaults(to: 0)
            }

            // Backfill: word count = number of non-empty whitespace/newline
            // separated tokens in the existing `text`, matching exactly what
            // `WordCounting.count(in:)` computes for freshly saved/edited
            // rows (`DM-006`). Done in Swift (not raw SQL) so the exact same
            // tokenizing rule backs both the backfill and every future
            // write — no risk of the two drifting apart.
            let rows = try Row.fetchCursor(db, sql: "SELECT id, text FROM transcripts")
            while let row = try rows.next() {
                let id: String = row["id"]
                let text: String = row["text"]
                try db.execute(
                    sql: "UPDATE transcripts SET wordCount = ? WHERE id = ?",
                    arguments: [WordCounting.count(in: text), id]
                )
            }
        }

        // DM-005: only active/interrupted local media jobs. The staged source
        // itself lives in Caches and is never represented by a path column.
        migrator.registerMigration("v3_import_queue") { db in
            try db.create(table: "import_jobs") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("createdAt", .integer).notNull()
                t.column("sourceFileName", .text).notNull()
                t.column("mediaKind", .text).notNull()
                t.column("durationMilliseconds", .integer)
                t.column("state", .text).notNull()
                t.column("progress", .double).notNull().defaults(to: 0)
                t.column("stageStartedAt", .integer).notNull()
                t.column("lastErrorCode", .text)
            }
            try db.execute(sql: "CREATE INDEX import_jobs_on_createdAt_id ON import_jobs (createdAt ASC, id ASC)")
        }

        return migrator
    }
}

/// Shared word-counting rule (`DM-006`): words are non-empty tokens split on
/// whitespace/newlines. Used identically by this migration's backfill and by
/// every write path that populates `wordCount` (`HistoryStore.save`/`edit`),
/// so a historical row's count and a freshly written row's count are always
/// computed the same way.
nonisolated public enum WordCounting {
    public static func count(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}
