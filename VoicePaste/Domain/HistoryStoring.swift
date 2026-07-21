import Foundation

/// Errors surfaced by `API-local-history` (see `spec/api.md`).
nonisolated public enum HistoryError: Error, Equatable, Sendable {
    case notFound
    case historyDisabled
}

/// The stable boundary between UI (`UI-004`, menu bar) and the local SQLite
/// history/vocabulary store (`L-008`, `DM-002`, `DM-003`, `DM-004`).
///
/// The conforming type MUST be a Swift `actor` running entirely off
/// `MainActor`, backed by a GRDB `DatabasePool` (`L-008`). This protocol is
/// the contract the `db` agent implements in `Data/HistoryStore.swift`; UI
/// code must depend on this protocol only, never on GRDB types directly.
public protocol HistoryStoring: Sendable {
    /// First/next page of lightweight rows, `createdAt DESC, id DESC`, no `rawText`/`text`.
    /// `cursor == nil` requests the first page. Page size is `HistoryPaging.pageSize`.
    func fetchPage(after cursor: TranscriptCursor?) async throws -> TranscriptPage

    /// Full record (including `rawText`/`text`) for a single selected item.
    func fetchDetail(id: UUID) async throws -> Transcript

    /// FTS5 search over `text` and `sourceFileName`, paginated like `fetchPage`.
    func search(query: String, after cursor: TranscriptCursor?) async throws -> TranscriptPage

    /// Live-refresh signal for a long-lived history window: yields (starting
    /// with an immediate initial tick) whenever the `transcripts` table
    /// changes — `save`/`edit`/`delete`/`clearAll` — so `HistoryView` can
    /// re-run whichever query (`fetchPage`/`search`) it's currently showing
    /// without requiring the window to be reopened or reactivated. Carries no
    /// data by design: `HistoryStoring` conformers already expose
    /// `fetchPage`/`search` for the actual rows. Declared `nonisolated`
    /// (not `async`) so an `actor` conformer can back it with a plain
    /// `AsyncStream`, independent of the actor's own isolation.
    nonisolated func changes() -> AsyncStream<Void>

    /// Persists a freshly produced transcript: record + preview + FTS index in one transaction.
    func save(_ transcript: Transcript) async throws

    /// Edits `text`/`preview`/`updatedAt` and the FTS index; `rawText` is preserved.
    func edit(id: UUID, text: String, updatedAt: Int64) async throws

    /// Deletes one record and its FTS row in a single transaction.
    func delete(id: UUID) async throws

    /// Deletes all history in one confirmed transaction.
    func clearAll() async throws

    /// Pre-aggregated local usage for a rolling day window. This deliberately
    /// reads only timestamps and word counts, never transcript text.
    func fetchUsageStats(now: Date, dayCount: Int) async throws -> UsageStats

    /// All active + inactive vocabulary entries (small table, no paging needed).
    func fetchVocabulary() async throws -> [VocabularyEntry]

    /// Inserts or updates a vocabulary entry by `id`.
    func upsertVocabulary(_ entry: VocabularyEntry) async throws

    /// Deletes a vocabulary entry by `id`.
    func deleteVocabulary(id: UUID) async throws
}

extension HistoryStoring {
    public func fetchUsageStats() async throws -> UsageStats {
        try await fetchUsageStats(now: Date(), dayCount: 30)
    }
}
