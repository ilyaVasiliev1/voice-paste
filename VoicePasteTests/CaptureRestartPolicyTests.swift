import Foundation
import Testing

@testable import VoicePaste

/// Повторы перезапуска захвата после смены устройства. Графа здесь нет:
/// перезапуск и ожидание подставные, проверяется только порядок попыток.
@Suite("Перезапуск захвата после смены устройства")
struct CaptureRestartPolicyTests {

    private struct NotReady: Error {}

    private final class Counter: @unchecked Sendable {
        var attempts = 0
        var pauses: [Duration] = []
    }

    @Test("с первой попытки — перезапущено, ждать не пришлось")
    func succeedsImmediately() async {
        let counter = Counter()

        let outcome = await CaptureRestartPolicy.run(
            restart: { counter.attempts += 1 },
            sleep: { counter.pauses.append($0) }
        )

        #expect(outcome == .restarted)
        #expect(counter.attempts == 1)
        #expect(counter.pauses.isEmpty)
    }

    @Test("гарнитура ещё не готова: две неудачи, третья попытка удалась")
    func succeedsAfterRetries() async {
        let counter = Counter()

        let outcome = await CaptureRestartPolicy.run(
            restart: {
                counter.attempts += 1
                if counter.attempts < 3 { throw NotReady() }
            },
            sleep: { counter.pauses.append($0) }
        )

        #expect(outcome == .restarted)
        #expect(counter.attempts == 3)
        #expect(counter.pauses == [.milliseconds(150), .milliseconds(150)])
    }

    @Test("не удалось ни разу — отказ после трёх попыток, без лишней паузы в конце")
    func failsAfterAllAttempts() async {
        let counter = Counter()

        let outcome = await CaptureRestartPolicy.run(
            restart: {
                counter.attempts += 1
                throw NotReady()
            },
            sleep: { counter.pauses.append($0) }
        )

        guard case .failed = outcome else {
            Issue.record("ожидался отказ, получено \(outcome)")
            return
        }
        #expect(counter.attempts == 3)
        #expect(counter.pauses.count == 2)
    }

    @Test("причина отказа не несёт пути пользователя")
    func failureReasonCarriesNoPath() async {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: 4,
            userInfo: [NSFilePathErrorKey: "/Users/someone/Library/secret.wav"]
        )

        let outcome = await CaptureRestartPolicy.run(
            attempts: 1,
            restart: { throw error },
            sleep: { _ in }
        )

        guard case .failed(let reason) = outcome else {
            Issue.record("ожидался отказ")
            return
        }
        #expect(!reason.contains("/Users"))
        #expect(reason.contains("NSCocoaErrorDomain"))
    }
}

@Suite("Краткая причина ошибки для журнала")
struct ErrorSummaryTests {

    @Test("домен и код, без пути и без переносов строк")
    func domainAndCodeOnly() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: 640,
            userInfo: [NSFilePathErrorKey: "/Users/someone/Library/x.wav", NSLocalizedDescriptionKey: "диск\nполон"]
        )

        let summary = ErrorSummary.describe(error)

        #expect(summary == "NSCocoaErrorDomain#640")
    }

    @Test("ошибка Swift — имя типа и случай")
    func swiftErrorNamesTypeAndCase() {
        #expect(ErrorSummary.describe(AudioCaptureError.microphoneUnavailable) == "AudioCaptureError.microphoneUnavailable")
    }
}
