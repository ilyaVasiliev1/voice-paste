import Foundation
import Testing

@testable import VoicePaste

/// Строка и кнопка «звук для оценки» в настройках: что показывается и что
/// происходит после удаления. Сам звук проверен в `EvaluationAudioTests`.
@MainActor
@Suite("Настройки: звук для оценки")
struct EvaluationAudioControlsModelTests {

    private struct Failure: Error {}

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = EvaluationAudioSummary(fileCount: 0, totalBytes: 0)
        private(set) var deleteCalls = 0
        func set(_ value: EvaluationAudioSummary) { lock.withLock { stored = value } }
        var summary: EvaluationAudioSummary { lock.withLock { stored } }
        func didDelete() { lock.withLock { deleteCalls += 1; stored = .init(fileCount: 0, totalBytes: 0) } }
    }

    @Test("пока звука нет — так и сказано")
    func emptyStateIsSaidPlainly() async {
        let counter = Counter()
        let model = EvaluationAudioControlsModel(summary: { counter.summary }, deleteAll: { 0 })

        await model.refresh()

        #expect(model.summaryText == NSLocalizedString("settings.evaluationAudio.empty", comment: ""))
        #expect(!model.canDelete)
    }

    @Test("есть записи — число и размер, удалить можно")
    func summaryShowsCountAndSize() async {
        let counter = Counter()
        counter.set(.init(fileCount: 3, totalBytes: 5 * 1_024 * 1_024))
        let model = EvaluationAudioControlsModel(summary: { counter.summary }, deleteAll: { 3 })

        await model.refresh()

        #expect(model.summaryText.contains("3"))
        #expect(model.summaryText.contains("МБ") || model.summaryText.contains("MB"))
        #expect(model.canDelete)
    }

    @Test("после удаления строка обновляется, ошибки нет")
    func deletionRefreshesTheSummary() async {
        let counter = Counter()
        counter.set(.init(fileCount: 2, totalBytes: 2_000_000))
        let model = EvaluationAudioControlsModel(
            summary: { counter.summary },
            deleteAll: { counter.didDelete(); return 2 }
        )
        await model.refresh()

        await model.deleteAll()

        #expect(counter.deleteCalls == 1)
        #expect(!model.canDelete)
        #expect(model.failureMessage == nil)
    }

    @Test("отказ удаления виден, а не молчит")
    func deletionFailureIsVisible() async {
        let counter = Counter()
        counter.set(.init(fileCount: 2, totalBytes: 2_000_000))
        let model = EvaluationAudioControlsModel(summary: { counter.summary }, deleteAll: { throw Failure() })
        await model.refresh()

        await model.deleteAll()

        #expect(model.failureMessage == NSLocalizedString("settings.evaluationAudio.deleteFailed", comment: ""))
        #expect(model.canDelete)
    }
}
