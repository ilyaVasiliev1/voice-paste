import Foundation

/// Plain domain model for a saved dictation/import result.
/// Mirrors `DM-002` exactly. No GRDB import here — persistence conformance
/// lives in `Data/PersistenceRecords.swift` (owned by the db agent).
nonisolated public struct Transcript: Codable, Identifiable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case dictation
        case file
    }

    public enum Status: String, Codable, Sendable {
        case completed
        case failed
    }

    public enum InsertionOutcome: String, Codable, Sendable {
        case inserted
        case copied
        case notRequested
    }

    /// Primary key.
    public var id: UUID
    /// Epoch milliseconds; part of the stable `createdAt DESC, id DESC` sort key.
    public var createdAt: Int64
    /// Epoch milliseconds; changes only when the text is edited.
    public var updatedAt: Int64
    public var source: Source
    /// Only the file name, never a path or a copy of the original file.
    public var sourceFileName: String?
    public var durationMilliseconds: Int
    /// BCP-47 language tag, when known.
    public var language: String?
    /// Recognition output before normalization; never rendered in the list.
    public var rawText: String
    /// Current editable text.
    public var text: String
    /// First 240 characters of `text`, kept in sync transactionally.
    public var preview: String
    public var status: Status
    public var insertionOutcome: InsertionOutcome

    public init(
        id: UUID,
        createdAt: Int64,
        updatedAt: Int64,
        source: Source,
        sourceFileName: String?,
        durationMilliseconds: Int,
        language: String?,
        rawText: String,
        text: String,
        preview: String,
        status: Status,
        insertionOutcome: InsertionOutcome
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.source = source
        self.sourceFileName = sourceFileName
        self.durationMilliseconds = durationMilliseconds
        self.language = language
        self.rawText = rawText
        self.text = text
        self.preview = preview
        self.status = status
        self.insertionOutcome = insertionOutcome
    }

    /// Truncates `text` to the DM-002 preview length (240 characters).
    public static func makePreview(from text: String) -> String {
        String(text.prefix(240))
    }
}
