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

    public func deleteAll() async throws {
        try await dbPool.write { db in try db.execute(sql: "DELETE FROM import_jobs") }
    }

    private nonisolated static func readJobs(_ db: Database) throws -> [ImportJob] {
        try Row.fetchAll(
            db,
            sql: "SELECT id, createdAt, sourceFileName, mediaKind, durationMilliseconds, state, progress, stageStartedAt, lastErrorCode FROM import_jobs ORDER BY createdAt ASC, id ASC"
        ).compactMap { row in
            guard let id = UUID(uuidString: row["id"] as String),
                  let kind = ImportJob.MediaKind(rawValue: row["mediaKind"] as String),
                  let state = ImportJob.State(rawValue: row["state"] as String) else { return nil }
            return ImportJob(
                id: id,
                fileName: row["sourceFileName"],
                createdAt: row["createdAt"],
                mediaKind: kind,
                durationMilliseconds: row["durationMilliseconds"],
                state: state,
                progress: row["progress"],
                stageStartedAt: row["stageStartedAt"],
                failureKey: row["lastErrorCode"]
            )
        }
    }

    private nonisolated static func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }
}
