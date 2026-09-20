import GRDB
import XCTest

@testable import VoicePaste

/// Требование «Лекция хранится целиком с абзацами и временем».
///
/// Против настоящей базы на временном файле — той же, что у приложения, с
/// теми же миграциями. Подделка здесь ничего бы не доказала: проверяется
/// именно транзакция, порядок абзацев и каскад при удалении.
@MainActor
final class LectureStoreTests: XCTestCase {

    /// Не неявно развёрнутый опционал: каталог задаётся в `setUp`, а до
    /// него у поля есть осмысленное значение — временный каталог системы.
    private var tempDirectory = FileManager.default.temporaryDirectory

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoicePasteTests-LectureStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        try await super.tearDown()
    }

    private func makePool() throws -> DatabasePool {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            // Каскадное удаление абзацев держится на внешнем ключе, а SQLite
            // по умолчанию их не проверяет. Приложение включает их в
            // `AppDatabase`; тест обязан работать в тех же условиях.
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        configuration.busyMode = .timeout(5)
        let pool = try DatabasePool(
            path: tempDirectory.appendingPathComponent("history.sqlite").path,
            configuration: configuration
        )
        try Migrations.migrator.migrate(pool)
        return pool
    }

    private func makeDetail(
        id: UUID = UUID(),
        title: String = "Лекция",
        paragraphs: [ParagraphSeed] = [
            ParagraphSeed(text: "Первый абзац.", start: 0, end: 4_000),
            ParagraphSeed(text: "Второй абзац.", start: 9_000, end: 13_000),
        ]
    ) -> LectureDetail {
        LectureDetail(
            lecture: Lecture(
                id: id,
                createdAt: 1_700_000_000_000,
                updatedAt: 1_700_000_000_000,
                title: title,
                durationMilliseconds: 13_000,
                language: "ru",
                wordCount: 4
            ),
            paragraphs: paragraphs.enumerated().map { index, seed in
                StoredLectureParagraph(
                    id: UUID(),
                    lectureID: id,
                    orderIndex: index,
                    startMilliseconds: seed.start,
                    endMilliseconds: seed.end,
                    text: seed.text
                )
            }
        )
    }

    // MARK: - Запись и чтение

    func test_savedLecture_survivesReopeningTheDatabase() async throws {
        let id = UUID()
        let detail = makeDetail(id: id)
        let pool = try makePool()
        try await LectureStore(dbPool: pool).save(detail)

        // Заново открытая база — единственная честная проверка того, что
        // запись дошла до диска, а не осталась в памяти пула.
        let reopened = try makePool()
        let loaded = try await LectureStore(dbPool: reopened).fetchDetail(id: id)

        XCTAssertEqual(loaded?.lecture.title, "Лекция")
        XCTAssertEqual(loaded?.paragraphs.count, 2)
        XCTAssertEqual(loaded?.lecture.language, "ru")
    }

    func test_paragraphs_areReadBackInTheirOriginalOrder() async throws {
        let id = UUID()
        let detail = makeDetail(
            id: id,
            paragraphs: [
                ParagraphSeed(text: "Раз.", start: 0, end: 1_000),
                ParagraphSeed(text: "Два.", start: 5_000, end: 6_000),
                ParagraphSeed(text: "Три.", start: 10_000, end: 11_000),
            ]
        )
        let store = LectureStore(dbPool: try makePool())
        try await store.save(detail)

        let loaded = try await store.fetchDetail(id: id)

        XCTAssertEqual(loaded?.paragraphs.map(\.text), ["Раз.", "Два.", "Три."])
        XCTAssertEqual(loaded?.paragraphs.map(\.orderIndex), [0, 1, 2])
    }

    func test_paragraphTimestamps_areStoredAsGiven() async throws {
        let id = UUID()
        let store = LectureStore(dbPool: try makePool())
        try await store.save(makeDetail(id: id))

        let loaded = try await store.fetchDetail(id: id)

        XCTAssertEqual(loaded?.paragraphs.first?.startMilliseconds, 0)
        XCTAssertEqual(loaded?.paragraphs.last?.endMilliseconds, 13_000)
    }

    /// Дописывание по ходу: экран отдаёт текущее состояние целиком, а не
    /// разницу. Повторное сохранение обязано заменять абзацы, а не копить их.
    func test_savingTheSameLectureAgain_replacesItsParagraphsInsteadOfAppending() async throws {
        let id = UUID()
        let store = LectureStore(dbPool: try makePool())
        try await store.save(makeDetail(id: id))

        try await store.save(makeDetail(id: id, title: "Дополненная", paragraphs: [ParagraphSeed(text: "Только один.", start: 0, end: 2_000)]))
        let loaded = try await store.fetchDetail(id: id)

        XCTAssertEqual(loaded?.paragraphs.count, 1)
        XCTAssertEqual(loaded?.lecture.title, "Дополненная")
    }

    func test_fetchAll_returnsNewestFirst() async throws {
        let store = LectureStore(dbPool: try makePool())
        var older = makeDetail(title: "Старая")
        older.lecture.createdAt = 1_000
        var newer = makeDetail(title: "Новая")
        newer.lecture.createdAt = 2_000
        try await store.save(older)
        try await store.save(newer)

        let all = try await store.fetchAll()

        XCTAssertEqual(all.map(\.title), ["Новая", "Старая"])
    }

    func test_fetchDetail_forUnknownId_returnsNil() async throws {
        let store = LectureStore(dbPool: try makePool())

        let loaded = try await store.fetchDetail(id: UUID())

        XCTAssertNil(loaded)
    }

    // MARK: - Переименование

    func test_rename_changesTitleAndUpdatedAt() async throws {
        let id = UUID()
        let store = LectureStore(dbPool: try makePool())
        try await store.save(makeDetail(id: id))

        try await store.rename(id: id, title: "Матанализ, лекция 3", updatedAt: 1_800_000_000_000)
        let loaded = try await store.fetchDetail(id: id)

        XCTAssertEqual(loaded?.lecture.title, "Матанализ, лекция 3")
        XCTAssertEqual(loaded?.lecture.updatedAt, 1_800_000_000_000)
    }

    func test_rename_ofUnknownLecture_throwsNotFound() async throws {
        let store = LectureStore(dbPool: try makePool())

        do {
            try await store.rename(id: UUID(), title: "Нет такой", updatedAt: 1)
            XCTFail("Переименование несуществующей лекции обязано отказать")
        } catch {
            XCTAssertEqual(error as? LectureStoreError, .notFound)
        }
    }

    // MARK: - Удаление

    func test_deletingALecture_removesItsParagraphsToo() async throws {
        let id = UUID()
        let pool = try makePool()
        let store = LectureStore(dbPool: pool)
        try await store.save(makeDetail(id: id))

        try await store.delete(id: id)

        let orphans = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lecture_paragraphs") ?? -1
        }
        XCTAssertEqual(orphans, 0, "Осиротевший абзац не принадлежит ничему и показан быть не может")
        let loaded = try await store.fetchDetail(id: id)
        XCTAssertNil(loaded)
    }

    func test_deletingOneLecture_leavesTheOtherIntact() async throws {
        let kept = UUID()
        let removed = UUID()
        let store = LectureStore(dbPool: try makePool())
        try await store.save(makeDetail(id: kept, title: "Остаётся"))
        try await store.save(makeDetail(id: removed, title: "Уходит"))

        try await store.delete(id: removed)

        let all = try await store.fetchAll()
        XCTAssertEqual(all.map(\.title), ["Остаётся"])
    }
}

/// Заготовка абзаца для тестов. Кортеж на три поля хуже читается и линтером
/// не пропускается.
private struct ParagraphSeed {
    let text: String
    let start: Int
    let end: Int
}
