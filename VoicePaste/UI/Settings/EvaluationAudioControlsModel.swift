import Foundation

/// Состояние блока «Звук для оценки» в настройках.
@MainActor
final class EvaluationAudioControlsModel: ObservableObject {
    @Published private(set) var summaryText = ""
    @Published private(set) var canDelete = false
    @Published private(set) var failureMessage: String?

    private let summary: () async -> EvaluationAudioSummary
    private let deleteAllAudio: () async throws -> Int

    init(
        summary: @escaping () async -> EvaluationAudioSummary,
        deleteAll: @escaping () async throws -> Int
    ) {
        self.summary = summary
        self.deleteAllAudio = deleteAll
    }

    func refresh() async {
        let current = await summary()
        canDelete = current.fileCount > 0
        if current.fileCount == 0 {
            summaryText = NSLocalizedString("settings.evaluationAudio.empty", comment: "")
        } else {
            let size = ByteCountFormatter.string(fromByteCount: Int64(current.totalBytes), countStyle: .file)
            summaryText = String(
                format: NSLocalizedString("settings.evaluationAudio.summary", comment: ""),
                current.fileCount, size
            )
        }
    }

    func deleteAll() async {
        failureMessage = nil
        do {
            _ = try await deleteAllAudio()
        } catch {
            failureMessage = NSLocalizedString("settings.evaluationAudio.deleteFailed", comment: "")
        }
        await refresh()
    }
}
