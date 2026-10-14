import Foundation

/// Связь «убрали запись из истории — убран её звук для оценки».
nonisolated public enum EvaluationAudioCleanup {
    public static func hook(
        for store: any EvaluationAudioStoring,
        log: @escaping @Sendable (String, String) -> Void
    ) -> @Sendable (HistoryDeletion) async -> Void {
        { deletion in
            do {
                switch deletion {
                case .record(let id): try await store.delete(id: id)
                case .all: _ = try await store.deleteAll()
                }
            } catch {
                // Отказ звука не отменяет удаление записи: она уже убрана.
                log("evaluationAudio.deleteFailed", ErrorSummary.describe(error))
            }
        }
    }
}
