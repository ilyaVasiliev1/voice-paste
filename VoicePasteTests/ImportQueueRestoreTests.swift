import Foundation
import GRDB
import Testing

@testable import VoicePaste

/// Что делает очередь импорта при чтении строк, которые эта версия не знает
/// (например, записанные новой версией приложения): задача не пропадает молча.
@Suite("Очередь импорта: чтение незнакомых строк")
struct ImportQueueRestoreTests {

    private func makePool(in directory: URL) throws -> DatabasePool {
        var configuration = Configuration()
        configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA journal_mode = WAL") }
        configuration.busyMode = .timeout(5)
        let pool = try DatabasePool(path: directory.appendingPathComponent("queue.sqlite").path, configuration: configuration)
        try Migrations.migrator.migrate(pool)
        return pool
    }

    private func insert(_ pool: DatabasePool, id: String, kind: String, state: String) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO import_jobs (id, createdAt, sourceFileName, mediaKind, durationMilliseconds, state, progress, stageStartedAt, lastErrorCode)
                VALUES (?, 1, 'lecture.mp4', ?, NULL, ?, 0, 1, NULL)
                """,
                arguments: [id, kind, state]
            )
        }
    }

    private func withPool(_ body: (DatabasePool) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(try makePool(in: directory))
    }

    @Test("незнакомое состояние — задача остаётся и показана как неудавшаяся")
    func unknownStateBecomesAFailedJob() async throws {
        try await withPool { pool in
            let id = UUID()
            try insert(pool, id: id.uuidString, kind: "video", state: "archiving")

            let jobs = try await ImportQueueStore(dbPool: pool).restoreJobs()

            #expect(jobs.count == 1)
            #expect(jobs.first?.id == id)
            #expect(jobs.first?.state == .failed)
            #expect(jobs.first?.failureKey == "import.error.unknownState")
        }
    }

    @Test("незнакомый вид носителя — задача остаётся, состояние не меняется")
    func unknownMediaKindKeepsTheJob() async throws {
        try await withPool { pool in
            let id = UUID()
            try insert(pool, id: id.uuidString, kind: "podcast", state: "queued")

            let jobs = try await ImportQueueStore(dbPool: pool).restoreJobs()

            #expect(jobs.count == 1)
            #expect(jobs.first?.id == id)
            #expect(jobs.first?.state == .queued)
        }
    }

    @Test("знакомые строки читаются как раньше")
    func knownRowsAreUnchanged() async throws {
        try await withPool { pool in
            let id = UUID()
            try insert(pool, id: id.uuidString, kind: "audio", state: "failed")

            let jobs = try await ImportQueueStore(dbPool: pool).restoreJobs()

            #expect(jobs.map(\.id) == [id])
            #expect(jobs.first?.state == .failed)
        }
    }
}
