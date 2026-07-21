import Foundation

/// Used only when opening/migrating `history.sqlite` fails at launch.
/// Per `data-model.md`: VoicePaste must not delete the file automatically —
/// it shows an error and keeps the app usable (current dictation still goes
/// to clipboard/insertion, it just can't be saved to history).
public actor FailingHistoryStore: HistoryStoring {
    public init() {}

    public func fetchPage(after cursor: TranscriptCursor?) async throws -> TranscriptPage {
        throw HistoryError.historyDisabled
    }

    public func fetchDetail(id: UUID) async throws -> Transcript {
        throw HistoryError.notFound
    }

    public func search(query: String, after cursor: TranscriptCursor?) async throws -> TranscriptPage {
        throw HistoryError.historyDisabled
    }

    public nonisolated func changes() -> AsyncStream<Void> {
        // Nothing can ever be saved through this store, so there is nothing
        // to live-refresh: an immediately-finished, empty stream.
        AsyncStream { $0.finish() }
    }

    public func save(_ transcript: Transcript) async throws {
        throw HistoryError.historyDisabled
    }

    public func edit(id: UUID, text: String, updatedAt: Int64) async throws {
        throw HistoryError.historyDisabled
    }

    public func delete(id: UUID) async throws {
        throw HistoryError.historyDisabled
    }

    public func clearAll() async throws {
        throw HistoryError.historyDisabled
    }

    public func fetchUsageStats(now: Date, dayCount: Int) async throws -> UsageStats {
        .empty
    }

    public func fetchVocabulary() async throws -> [VocabularyEntry] {
        []
    }

    public func upsertVocabulary(_ entry: VocabularyEntry) async throws {
        throw HistoryError.historyDisabled
    }

    public func deleteVocabulary(id: UUID) async throws {
        throw HistoryError.historyDisabled
    }
}
