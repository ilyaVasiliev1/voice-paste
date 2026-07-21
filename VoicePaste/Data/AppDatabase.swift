import Foundation
import GRDB

/// Owns the single GRDB `DatabasePool` for VoicePaste's local history/
/// vocabulary store (`data-model.md`: `~/Library/Application Support/
/// VoicePaste/history.sqlite`, WAL journal, migrations).
public enum AppDatabase {
    public enum DatabaseError: Error, Sendable {
        case openFailed(String)
    }

    /// `~/Library/Application Support/VoicePaste/history.sqlite`.
    public static func historyDatabaseURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport.appendingPathComponent("VoicePaste", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("history.sqlite")
    }

    /// Opens (creating if needed) the WAL-journaled pool and runs migrations.
    /// - Throws: `DatabaseError.openFailed` if migration or open fails; per
    ///   `data-model.md` the caller must NOT delete the file automatically on
    ///   failure — surface the error and offer diagnostics instead.
    public static func makePool() throws -> DatabasePool {
        let url = try historyDatabaseURL()
        var configuration = Configuration()
        // `DatabasePool` already opens its writer connection in WAL mode by
        // default, but this is set explicitly so the on-disk journal mode is
        // never left ambiguous (`data-model.md`: "Включены WAL-журнал").
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        // Foreign keys are on by default in GRDB's `Configuration`; kept
        // implicit here since `transcripts_fts` uses GRDB-generated triggers
        // rather than a declared foreign key.
        // A bounded busy timeout (instead of the default immediate
        // `SQLITE_BUSY` error) lets the serialized `HistoryStore` writer wait
        // out brief WAL checkpoint contention instead of failing a save.
        configuration.busyMode = .timeout(5)
        do {
            let pool = try DatabasePool(path: url.path, configuration: configuration)
            try Migrations.migrator.migrate(pool)
            return pool
        } catch {
            // Never delete `url` here: an unreadable/half-migrated file must
            // stay on disk for diagnostics/manual recovery per
            // `data-model.md` "Загрузка истории".
            throw DatabaseError.openFailed(String(describing: error))
        }
    }
}
