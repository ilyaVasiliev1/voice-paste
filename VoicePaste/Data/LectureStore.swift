import Foundation
import GRDB

public enum LectureStoreError: Error, Equatable, Sendable {
    case notFound
}

/// Что умеет хранилище лекций. Протокол — чтобы экран и запись можно было
/// проверять без базы, как это уже сделано для истории.
public protocol LectureStoring: Sendable {
    func save(_ detail: LectureDetail) async throws
    func fetchAll() async throws -> [Lecture]
    func fetchDetail(id: UUID) async throws -> LectureDetail?
    func rename(id: UUID, title: String, updatedAt: Int64) async throws
    func delete(id: UUID) async throws
}

/// Лекции в том же `history.sqlite`, что и всё остальное: одна база — одна
/// резервная копия и одно место, которое пользователь удаляет при деинсталляции.
///
/// Устроено как `HistoryStore`: актор поверх `DatabasePool`, только
/// асинхронные `read`/`write`, поэтому исполнитель актора никогда не стоит на
/// файловом вводе-выводе.
public actor LectureStore: LectureStoring {
    private let dbPool: DatabasePool

    public init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    /// Лекция и её абзацы пишутся одной транзакцией: половина лекции без
    /// абзацев — не запись, а мусор, который нечем показать.
    ///
    /// Повторное сохранение той же лекции заменяет её абзацы целиком. Так
    /// работает дописывание по ходу: экран отдаёт текущее состояние, а не
    /// разницу, и расходиться с базой ему нечем.
    public func save(_ detail: LectureDetail) async throws {
        let lecture = detail.lecture
        let paragraphs = detail.paragraphs
        try await dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO lectures
                        (id, createdAt, updatedAt, title, durationMilliseconds, language, wordCount)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        updatedAt = excluded.updatedAt,
                        title = excluded.title,
                        durationMilliseconds = excluded.durationMilliseconds,
                        language = excluded.language,
                        wordCount = excluded.wordCount
                    """,
                arguments: [
                    lecture.id.uuidString, lecture.createdAt, lecture.updatedAt,
                    lecture.title, lecture.durationMilliseconds, lecture.language,
                    lecture.wordCount,
                ]
            )
            try db.execute(
                sql: "DELETE FROM lecture_paragraphs WHERE lectureId = ?",
                arguments: [lecture.id.uuidString]
            )
            for paragraph in paragraphs {
                try db.execute(
                    sql: """
                        INSERT INTO lecture_paragraphs
                            (id, lectureId, orderIndex, startMilliseconds, endMilliseconds, text)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        paragraph.id.uuidString, lecture.id.uuidString, paragraph.orderIndex,
                        paragraph.startMilliseconds, paragraph.endMilliseconds, paragraph.text,
                    ]
                )
            }
        }
    }

    public func fetchAll() async throws -> [Lecture] {
        try await dbPool.read { db in
            try Row
                .fetchAll(
                    db,
                    sql: """
                        SELECT id, createdAt, updatedAt, title, durationMilliseconds, language, wordCount
                        FROM lectures ORDER BY createdAt DESC, id DESC
                        """
                )
                .compactMap(Self.lecture(from:))
        }
    }

    public func fetchDetail(id: UUID) async throws -> LectureDetail? {
        try await dbPool.read { db in
            let lectureRow = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, createdAt, updatedAt, title, durationMilliseconds, language, wordCount
                    FROM lectures WHERE id = ?
                    """,
                arguments: [id.uuidString]
            )
            guard let lectureRow, let lecture = Self.lecture(from: lectureRow) else { return nil }

            let paragraphs = try Row
                .fetchAll(
                    db,
                    sql: """
                        SELECT id, lectureId, orderIndex, startMilliseconds, endMilliseconds, text
                        FROM lecture_paragraphs WHERE lectureId = ? ORDER BY orderIndex ASC
                        """,
                    arguments: [id.uuidString]
                )
                .compactMap(Self.paragraph(from:))
            return LectureDetail(lecture: lecture, paragraphs: paragraphs)
        }
    }

    public func rename(id: UUID, title: String, updatedAt: Int64) async throws {
        let changed = try await dbPool.write { db -> Int in
            try db.execute(
                sql: "UPDATE lectures SET title = ?, updatedAt = ? WHERE id = ?",
                arguments: [title, updatedAt, id.uuidString]
            )
            return db.changesCount
        }
        guard changed > 0 else { throw LectureStoreError.notFound }
    }

    public func delete(id: UUID) async throws {
        try await dbPool.write { db in
            // Абзацы уходят каскадом — внешний ключ объявлен в миграции.
            try db.execute(sql: "DELETE FROM lectures WHERE id = ?", arguments: [id.uuidString])
        }
    }

    // MARK: - Чтение строк
    //
    // Строка с неразобранным идентификатором отбрасывается, но молча этого не
    // происходит: битая строка — повод узнать о ней, а не потерять лекцию без
    // следа.

    private nonisolated static func lecture(from row: Row) -> Lecture? {
        guard let id = UUID(uuidString: row["id"] as String) else {
            logDroppedRow(table: "lectures", id: row["id"] as String)
            return nil
        }
        return Lecture(
            id: id,
            createdAt: row["createdAt"],
            updatedAt: row["updatedAt"],
            title: row["title"],
            durationMilliseconds: row["durationMilliseconds"],
            language: row["language"],
            wordCount: row["wordCount"]
        )
    }

    private nonisolated static func paragraph(from row: Row) -> StoredLectureParagraph? {
        guard let id = UUID(uuidString: row["id"] as String),
            let lectureID = UUID(uuidString: row["lectureId"] as String)
        else {
            logDroppedRow(table: "lecture_paragraphs", id: row["id"] as String)
            return nil
        }
        return StoredLectureParagraph(
            id: id,
            lectureID: lectureID,
            orderIndex: row["orderIndex"],
            startMilliseconds: row["startMilliseconds"],
            endMilliseconds: row["endMilliseconds"],
            text: row["text"]
        )
    }

    private nonisolated static func logDroppedRow(table: String, id: String) {
        Task { await DiagnosticLog.shared.log("lecture.rowDropped", detail: "\(table):\(id)") }
    }
}
