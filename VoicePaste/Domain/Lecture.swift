import Foundation

/// Записанная лекция: долгая запись, которую читают и к которой возвращаются.
///
/// Отдельна от `Transcript` намеренно. У расшифровки диктовки жизнь короткая —
/// вставить в чужое окно и забыть; у лекции есть длительность в часах, абзацы
/// со своим временем и смысл возвращаться к месту.
nonisolated public struct Lecture: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var createdAt: Int64
    public var updatedAt: Int64
    public var title: String
    public var durationMilliseconds: Int
    public var language: String?
    public var wordCount: Int

    public init(
        id: UUID,
        createdAt: Int64,
        updatedAt: Int64,
        title: String,
        durationMilliseconds: Int,
        language: String?,
        wordCount: Int
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.title = title
        self.durationMilliseconds = durationMilliseconds
        self.language = language
        self.wordCount = wordCount
    }

    /// Название по умолчанию — дата и время начала. Лекцию можно
    /// переименовать, но безымянной она не остаётся: список из десятка
    /// «Без названия» бесполезен.
    public static func defaultTitle(startedAt: Date, formatter: DateFormatter) -> String {
        formatter.string(from: startedAt)
    }
}

/// Абзац лекции — несколько сегментов подряд без заметной паузы между ними.
/// Хранится со своим временем, чтобы к месту в записи можно было вернуться.
nonisolated public struct StoredLectureParagraph: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let lectureID: UUID
    public var orderIndex: Int
    public var startMilliseconds: Int
    public var endMilliseconds: Int
    public var text: String

    public init(
        id: UUID,
        lectureID: UUID,
        orderIndex: Int,
        startMilliseconds: Int,
        endMilliseconds: Int,
        text: String
    ) {
        self.id = id
        self.lectureID = lectureID
        self.orderIndex = orderIndex
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.text = text
    }
}

/// Лекция вместе с её абзацами — то, что показывает экран и что пишется одной
/// транзакцией.
nonisolated public struct LectureDetail: Sendable, Equatable {
    public var lecture: Lecture
    public var paragraphs: [StoredLectureParagraph]

    public init(lecture: Lecture, paragraphs: [StoredLectureParagraph]) {
        self.lecture = lecture
        self.paragraphs = paragraphs
    }

    /// Весь текст подряд — для копирования и подсчёта слов.
    public var plainText: String {
        paragraphs.map(\.text).joined(separator: "\n\n")
    }
}
