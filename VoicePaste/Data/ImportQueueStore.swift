import Foundation
import GRDB

/// SQLite implementation of `DM-005`. Jobs are deliberately tiny and only
/// describe work owned by the local cache; no path, bookmark or media bytes
/// are ever written to the database.
public actor ImportQueueStore: ImportQueueStoring {
    private nonisolated let dbPool: DatabasePool

    public init(dbPool: DatabasePool) { self.dbPool = dbPool }

    public func restoreJobs() async throws -> [ImportJob] {
        let now = Self.nowMillis()
        return try await dbPool.write { db in
            // A process cannot resume an in-flight AVFoundation/Whisper task.
            // It safely restarts from staged source on the next launch.
            try db.execute(
                sql: "UPDATE import_jobs SET state = 'queued', progress = 0, stageStartedAt = ? WHERE state IN ('staging', 'preparing', 'transcribing', 'paused')",
                arguments: [now]
            )
            return try Self.readJobs(db)
        }
    }

    public func upsert(_ job: ImportJob) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO import_jobs (
                    id, createdAt, sourceFileName, mediaKind, durationMilliseconds,
                    state, progress, stageStartedAt, lastErrorCode
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    sourceFileName = excluded.sourceFileName,
                    mediaKind = excluded.mediaKind,
                    durationMilliseconds = excluded.durationMilliseconds,
                    state = excluded.state,
                    progress = excluded.progress,
                    stageStartedAt = excluded.stageStartedAt,
                    lastErrorCode = excluded.lastErrorCode
                """,
                arguments: [
                    job.id.uuidString, job.createdAt, job.fileName, job.mediaKind.rawValue,
                    job.durationMilliseconds, job.state.rawValue, job.progress,
                    job.stageStartedAt, job.failureKey,
                ]
            )
        }
    }

    public func delete(id: UUID) async throws {
        try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM import_jobs WHERE id = ?", arguments: [id.uuidString])
        }
    }

    /// Незнакомое состояние или вид носителя (строку записала другая версия) не отбрасывается:
    /// задача остаётся и показана как неудавшаяся, чтобы её можно было увидеть и убрать.
    private nonisolated static func readJobs(_ db: Database) throws -> [ImportJob] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, createdAt, sourceFileName, mediaKind, durationMilliseconds, state, progress, stageStartedAt, lastErrorCode FROM import_jobs ORDER BY createdAt ASC, id ASC"
        )
        var unreadable = 0
        let jobs: [ImportJob] = rows.compactMap { row in
            guard let id = UUID(uuidString: row["id"] as String) else {
                unreadable += 1
                return nil
            }
            let kind = ImportJob.MediaKind(rawValue: row["mediaKind"] as String) ?? .audio
            let storedState = ImportJob.State(rawValue: row["state"] as String)
            return ImportJob(
                id: id,
                fileName: row["sourceFileName"],
                createdAt: row["createdAt"],
                mediaKind: kind,
                durationMilliseconds: row["durationMilliseconds"],
                state: storedState ?? .failed,
                progress: row["progress"],
                stageStartedAt: row["stageStartedAt"],
                failureKey: storedState == nil ? "import.error.unknownState" : row["lastErrorCode"]
            )
        }
        if unreadable > 0 {
            let count = unreadable
            Task { await DiagnosticLog.shared.log("import.restore.unreadableRows", detail: "count=\(count)") }
        }
        return jobs
    }

    private nonisolated static func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }
}
