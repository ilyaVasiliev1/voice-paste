import Foundation
import GRDB

/// GRDB record conformances for the plain `Domain/` models.
///
/// Kept separate from `Transcript`/`VocabularyEntry` themselves so `Domain/`
/// stays free of GRDB imports (those types must stay portable/pure Codable).
///
/// `id` is decoded/encoded as its `uuidString` (matching `DM-002`/`DM-004`'s
/// literal "UUID / TEXT" column type) rather than GRDB's default UUID
/// database representation, which stores a 16-byte BLOB. Keeping the primary
/// key as human-readable TEXT matches the schema in `Migrations.swift`
/// exactly and avoids BLOB values landing in a TEXT-affinity column.
///
/// Marked `nonisolated` throughout: these conformances/methods must be
/// usable from the `HistoryStore` actor (off `MainActor`), not just from the
/// UI — the module's default-MainActor-isolation build setting otherwise
/// applies here too.

nonisolated extension Transcript: TableRecord {
    public static let databaseTableName = "transcripts"
}

nonisolated extension Transcript: FetchableRecord, PersistableRecord {
    public init(row: Row) throws {
        guard let id = UUID(uuidString: row["id"] as String) else {
            throw DatabaseError(message: "Transcript: invalid id column")
        }
        guard let source = Source(rawValue: row["source"] as String) else {
            throw DatabaseError(message: "Transcript: invalid source column")
        }
        guard let status = Status(rawValue: row["status"] as String) else {
            throw DatabaseError(message: "Transcript: invalid status column")
        }
        guard let insertionOutcome = InsertionOutcome(rawValue: row["insertionOutcome"] as String) else {
            throw DatabaseError(message: "Transcript: invalid insertionOutcome column")
        }
        self.init(
            id: id,
            createdAt: row["createdAt"],
            updatedAt: row["updatedAt"],
            source: source,
            sourceFileName: row["sourceFileName"],
            durationMilliseconds: row["durationMilliseconds"],
            language: row["language"],
            rawText: row["rawText"],
            text: row["text"],
            preview: row["preview"],
            status: status,
            insertionOutcome: insertionOutcome
        )
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id.uuidString
        container["createdAt"] = createdAt
        container["updatedAt"] = updatedAt
        container["source"] = source.rawValue
        container["sourceFileName"] = sourceFileName
        container["durationMilliseconds"] = durationMilliseconds
        container["language"] = language
        container["rawText"] = rawText
        container["text"] = text
        container["preview"] = preview
        container["status"] = status.rawValue
        container["insertionOutcome"] = insertionOutcome.rawValue
        // `DM-006`: derived from `text` at encode time (not a stored
        // `Transcript` property) so it can never drift from `text` on any
        // path that goes through `insert`/`update` — `HistoryStore.edit`
        // additionally sets it directly since that path updates `text` via
        // raw SQL rather than through this record's `encode(to:)`.
        container["wordCount"] = WordCounting.count(in: text)
    }
}

nonisolated extension TranscriptListItem: TableRecord {
    public static let databaseTableName = "transcripts"
}

nonisolated extension TranscriptListItem: FetchableRecord {
    public init(row: Row) throws {
        // Lightweight sidebar row (`data-model.md` "Загрузка истории"):
        // deliberately never decodes `rawText`/`text`. Callers must SELECT
        // only the lightweight columns for this to hold in practice.
        guard let id = UUID(uuidString: row["id"] as String) else {
            throw DatabaseError(message: "TranscriptListItem: invalid id column")
        }
        guard let source = Transcript.Source(rawValue: row["source"] as String) else {
            throw DatabaseError(message: "TranscriptListItem: invalid source column")
        }
        guard let status = Transcript.Status(rawValue: row["status"] as String) else {
            throw DatabaseError(message: "TranscriptListItem: invalid status column")
        }
        guard let insertionOutcome = Transcript.InsertionOutcome(rawValue: row["insertionOutcome"] as String) else {
            throw DatabaseError(message: "TranscriptListItem: invalid insertionOutcome column")
        }
        self.init(
            id: id,
            createdAt: row["createdAt"],
            updatedAt: row["updatedAt"],
            source: source,
            sourceFileName: row["sourceFileName"],
            durationMilliseconds: row["durationMilliseconds"],
            language: row["language"],
            preview: row["preview"],
            status: status,
            insertionOutcome: insertionOutcome
        )
    }
}

nonisolated extension VocabularyEntry: TableRecord {
    public static let databaseTableName = "vocabulary_entries"
}

nonisolated extension VocabularyEntry: FetchableRecord, PersistableRecord {
    public init(row: Row) throws {
        guard let id = UUID(uuidString: row["id"] as String) else {
            throw DatabaseError(message: "VocabularyEntry: invalid id column")
        }
        self.init(
            id: id,
            spokenForm: row["spokenForm"],
            replacement: row["replacement"],
            isEnabled: row["isEnabled"],
            createdAt: row["createdAt"],
            updatedAt: row["updatedAt"]
        )
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id.uuidString
        container["spokenForm"] = spokenForm
        container["replacement"] = replacement
        container["isEnabled"] = isEnabled
        container["createdAt"] = createdAt
        container["updatedAt"] = updatedAt
    }
}
