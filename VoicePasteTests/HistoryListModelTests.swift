import GRDB
import XCTest

@testable import VoicePaste

/// «Открыть в истории» из плашки выбирает запись, когда окно только
/// появляется. Модель обязана показать её текст независимо от того, что
/// случилось раньше — выбор или подключение хранилища: порядок `onAppear` и
/// `.task` SwiftUI не гарантирует.
@MainActor
final class HistoryListModelTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryListModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
        tempDirectory = nil
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

    func test_selectionMadeBeforeStoreIsAttached_stillLoadsTheRecord() async throws {
        let id = UUID()
        let store = try await makeStoreWithRecord(id: id)
        let model = HistoryListModel()

        model.selection = id
        // Загрузка по выбору успевает отработать впустую — как в окне, где
        // `onAppear` прошёл, а `.task` с подключением ещё не начался.
        try await Task.sleep(for: .milliseconds(100))
        model.attach(store)
        try await waitForDetail(model)

        XCTAssertEqual(model.detail?.id, id, "выбор до подключения хранилища оставил деталь пустой")
    }

    func test_selectionAfterAttach_loadsTheRecord() async throws {
        let id = UUID()
        let store = try await makeStoreWithRecord(id: id)
        let model = HistoryListModel()

        model.attach(store)
        model.selection = id
        try await waitForDetail(model)

        XCTAssertEqual(model.detail?.id, id)
    }
}
