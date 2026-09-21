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
}
