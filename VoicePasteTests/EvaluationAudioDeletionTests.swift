import Foundation
import GRDB
import Testing

@testable import VoicePaste

/// Удалил запись из истории — звук для оценки ушёл вместе с ней.
@Suite("Звук для оценки и удаление записей", .serialized)
struct EvaluationAudioDeletionTests {

    private static func tone() -> [Float] { (0..<1_600).map { 0.3 * sin(Float($0) * 0.05) } }

    // MARK: - Хранилище звука

    @Test("удаление по идентификатору стирает файл записи и недописанные хвосты, чужие остаются")
    func storeDeletesOnlyThatRecordsFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EvalDelete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationAudioStore(directory: directory)
        let target = UUID()
        let other = UUID()
        try await store.save(samples: Self.tone(), id: target)
        try await store.save(samples: Self.tone(), id: other)
        let leftover = directory.appendingPathComponent("\(target.uuidString).wav.sb-12ab-XyZ")
        try Data(repeating: 1, count: 16).write(to: leftover)

        try await store.delete(id: target)

        let remaining = (try FileManager.default.contentsOfDirectory(atPath: directory.path)).sorted()
        #expect(remaining == ["\(other.uuidString).wav"])
    }

    @Test("удаление записи без звука — без ошибки")
    func deletingMissingAudioIsHarmless() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EvalDelete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationAudioStore(directory: directory)

        try await store.delete(id: UUID())
    }

    // MARK: - Обработчик

    @Test("обработчик: удалена запись — стёрт её звук")
    func hookDeletesRecordAudio() async {
        let fake = FakeEvaluationAudio()
        let id = UUID()

        await EvaluationAudioCleanup.hook(for: fake, log: { _, _ in })(.record(id))

        #expect(fake.deletedIDs == [id])
        #expect(fake.deleteAllCount == 0)
    }

    @Test("обработчик: очищена история — стёрт весь звук")
    func hookDeletesEverythingOnClearAll() async {
        let fake = FakeEvaluationAudio()

        await EvaluationAudioCleanup.hook(for: fake, log: { _, _ in })(.all)

        #expect(fake.deleteAllCount == 1)
        #expect(fake.deletedIDs.isEmpty)
    }

    @Test("обработчик: отказ удаления уходит в журнал без пути и не бросается")
    func hookFailureIsLoggedNotThrown() async {
        let fake = FakeEvaluationAudio()
        fake.setDeleteFailure(NSError(
            domain: NSCocoaErrorDomain, code: 513,
            userInfo: [NSFilePathErrorKey: "/Users/someone/Library/x.wav"]
        ))
        let log = EventLogBox()

        await EvaluationAudioCleanup.hook(for: fake, log: { log.append($0, $1) })(.record(UUID()))

        #expect(log.entries.count == 1)
        #expect(log.entries.first?.0 == "evaluationAudio.deleteFailed")
        #expect(log.entries.first?.1 == "NSCocoaErrorDomain#513")
    }

    // MARK: - Хранилище истории

    private func makeHistory(
        onDeleted: @escaping @Sendable (HistoryDeletion) async -> Void
    ) throws -> (store: HistoryStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryHook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.prepareDatabase { try $0.execute(sql: "PRAGMA journal_mode = WAL") }
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("history.sqlite").path,
            configuration: configuration
        )
        try Migrations.migrator.migrate(pool)
        return (HistoryStore(dbPool: pool, onDeleted: onDeleted), directory)
    }

    private func transcript(id: UUID = UUID()) -> Transcript {
        Transcript(
            id: id, createdAt: 1, updatedAt: 1, source: .dictation, sourceFileName: nil,
            durationMilliseconds: 1_000, language: "ru", rawText: "текст", text: "текст",
            preview: "текст", status: .completed, insertionOutcome: .notRequested
        )
    }

    @Test("история: удаление записи сообщает её идентификатор")
    func historyDeleteReportsRecord() async throws {
        let box = DeletionBox()
        let (store, directory) = try makeHistory(onDeleted: { box.append($0) })
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        try await store.save(transcript(id: id))

        try await store.delete(id: id)

        #expect(box.items == [.record(id)])
    }

    @Test("история: очистка сообщает «всё»")
    func historyClearAllReportsAll() async throws {
        let box = DeletionBox()
        let (store, directory) = try makeHistory(onDeleted: { box.append($0) })
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.save(transcript())

        try await store.clearAll()

        #expect(box.items == [.all])
    }

    @Test("история: удаление несуществующей записи ничего не сообщает")
    func historyFailedDeleteReportsNothing() async throws {
        let box = DeletionBox()
        let (store, directory) = try makeHistory(onDeleted: { box.append($0) })
        defer { try? FileManager.default.removeItem(at: directory) }

        await #expect(throws: (any Error).self) { try await store.delete(id: UUID()) }

        #expect(box.items.isEmpty)
    }
}

private final class DeletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [HistoryDeletion] = []
    var items: [HistoryDeletion] { lock.withLock { stored } }
    func append(_ item: HistoryDeletion) { lock.withLock { stored.append(item) } }
}

private final class EventLogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(String, String)] = []
    var entries: [(String, String)] { lock.withLock { stored } }
    func append(_ event: String, _ detail: String) { lock.withLock { stored.append((event, detail)) } }
}
