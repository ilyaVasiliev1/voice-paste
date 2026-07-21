import Foundation

/// Lightweight sidebar row for the history split view.
/// Per `data-model.md` "Загрузка истории": list pages never carry `rawText`
/// or the full `text`, only the precomputed `preview`.
nonisolated public struct TranscriptListItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Int64
    public var updatedAt: Int64
    public var source: Transcript.Source
    public var sourceFileName: String?
    public var durationMilliseconds: Int
    public var language: String?
    public var preview: String
    public var status: Transcript.Status
    public var insertionOutcome: Transcript.InsertionOutcome

    public init(
        id: UUID,
        createdAt: Int64,
        updatedAt: Int64,
        source: Transcript.Source,
        sourceFileName: String?,
        durationMilliseconds: Int,
        language: String?,
        preview: String,
        status: Transcript.Status,
        insertionOutcome: Transcript.InsertionOutcome
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.source = source
        self.sourceFileName = sourceFileName
        self.durationMilliseconds = durationMilliseconds
        self.language = language
        self.preview = preview
        self.status = status
        self.insertionOutcome = insertionOutcome
    }
}

/// Stable keyset-pagination cursor: `createdAt DESC, id DESC` (DM-002).
nonisolated public struct TranscriptCursor: Equatable, Sendable {
    public var createdAt: Int64
    public var id: UUID

    public init(createdAt: Int64, id: UUID) {
        self.createdAt = createdAt
        self.id = id
    }
}

/// One page of history rows, at most 100 per `data-model.md`.
nonisolated public struct TranscriptPage: Equatable, Sendable {
    public var items: [TranscriptListItem]
    public var nextCursor: TranscriptCursor?

    public init(items: [TranscriptListItem], nextCursor: TranscriptCursor?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// Page size mandated everywhere history/search paginates (DM-002/DM-003).
nonisolated public enum HistoryPaging {
    public static let pageSize = 100
}
