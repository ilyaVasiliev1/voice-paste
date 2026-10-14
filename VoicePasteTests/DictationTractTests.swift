import Foundation
import GRDB
import Testing

@testable import VoicePaste

/// Тракт диктовки целиком: от остановки записи до вставки и истории.
///
/// Микрофон, вставка, плашка и часы — подставные, модель — счётчик вызовов.
/// Так видно то, что раньше проверялось только живьём: что доходит до
/// модели, что нет, и чем кончается каждая ветка.
@MainActor
@Suite("Тракт диктовки", .serialized)
struct DictationTractTests {

    // MARK: - Стенд

    struct Rig {
        let state: AppState
        let audio: FakeAudioSource
        let delivery: FakeTextDelivery
        let hud: FakeHUD
        let engine: CountingTranscriber
        let store: HistoryStore
        let settings: AppSettings
        let events: EventLog
        let evaluation: FakeEvaluationAudio
        let cleanup: () -> Void
    }

    static let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    func makeRig(
        engineResult: Result<TranscriptionResult, Error> = .success(
            TranscriptionResult(rawText: "Привет, мир.", detectedLanguage: "ru")
        ),
        autoInsert: Bool = true,
        ready: Bool = true,
        saveAudio: Bool = false
    ) async throws -> Rig {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationTract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let defaults = try #require(UserDefaults(suiteName: "DictationTract-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        settings.autoInsertEnabled = autoInsert
        settings.historyEnabled = true
        settings.saveAudioForEvaluation = saveAudio

        var configuration = Configuration()
        configuration.prepareDatabase { try $0.execute(sql: "PRAGMA journal_mode = WAL") }
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("history.sqlite").path,
            configuration: configuration
        )
        try Migrations.migrator.migrate(pool)
        let store = HistoryStore(dbPool: pool)

        let engine = CountingTranscriber(result: engineResult)
        let modelManager = ModelManager(
            modelDirectory: directory.appendingPathComponent("model", isDirectory: true),
            makeTranscriber: { _, _, _ in engine }
        )
        _ = try await modelManager.installModel()

        let audio = FakeAudioSource()
        let delivery = FakeTextDelivery()
        let hud = FakeHUD()
        let events = EventLog()
        let evaluation = FakeEvaluationAudio()
        let importManager = ImportManager(
            modelManager: modelManager,
            historyStore: store,
            queueStore: InMemoryImportQueueStore(),
            settings: settings
        )
        let state = AppState(
            settings: settings,
            modelManager: modelManager,
            historyStore: store,
            importManager: importManager,
            enableGlobalHotkey: false,
            audioSource: audio,
            textDelivery: delivery,
            hud: hud,
            now: { Self.fixedNow },
            isDictationReady: { ready },
            logEvent: { events.append($0, $1) },
            evaluationAudio: evaluation
        )
        return Rig(
            state: state, audio: audio, delivery: delivery, hud: hud,
            engine: engine, store: store, settings: settings, events: events, evaluation: evaluation,
            cleanup: { try? FileManager.default.removeItem(at: directory) }
        )
    }

    /// Речь: одна секунда синусоиды заметной громкости.
    static func speech(seconds: Double = 1.0, amplitude: Float = 0.1) -> [Float] {
        (0..<Int(seconds * 16_000)).map { amplitude * sin(Float($0) * 0.05) }
    }

    /// Нажать клавишу, «наговорить», нажать ещё раз и дождаться конца расшифровки.
    func dictate(_ rig: Rig, samples: [Float], rms: Float) async {
        rig.audio.recording = samples
        rig.audio.recordingRMS = rms
        rig.state.handleHotkeyDown()
        rig.state.handleHotkeyDown()
        await rig.state.dictationTask?.value
        await rig.state.evaluationAudioTask?.value
    }

    func savedItems(_ rig: Rig) async throws -> [TranscriptListItem] {
        try await rig.store.fetchPage(after: nil).items
    }

    // MARK: - До модели

    @Test("запись короче половины секунды не доходит до модели")
    func tooShortRecordingNeverReachesTheModel() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }

        await dictate(rig, samples: Array(Self.speech().prefix(4_000)), rms: 0.07)

        #expect(rig.engine.callCount == 0)
        #expect(rig.hud.last == .error(message: NSLocalizedString("dictation.emptyAudio", comment: "")))
        #expect(rig.delivery.inserted.isEmpty && rig.delivery.copied.isEmpty)
        #expect(try await savedItems(rig).isEmpty)
        #expect(rig.state.dictationPhase == .idle)
    }

    @Test("тишина на всю запись не доходит до модели")
    func silentRecordingNeverReachesTheModel() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }

        await dictate(rig, samples: Self.speech(seconds: 2, amplitude: 0.0005), rms: 0.0004)

        #expect(rig.engine.callCount == 0)
        #expect(rig.hud.last == .error(message: NSLocalizedString("dictation.emptyAudio", comment: "")))
        #expect(try await savedItems(rig).isEmpty)
    }

    @Test("диктовка пишет в журнал режим и язык, текста там нет")
    func dictationJournalsLanguageWithoutText() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }

        await dictate(rig, samples: Self.speech(), rms: 0.07)

        let entries = rig.events.details(of: "dictation.language")
        #expect(entries.count == 1)
        #expect(entries.first?.contains("mode=ru") == true)
        #expect(entries.first?.contains("detected=ru") == true)
        #expect(entries.first?.contains("Привет") == false)
    }

    @Test("ровный шум громче порога не доходит до модели")
    func steadyNoiseNeverReachesTheModel() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }

        // Средняя громкость 0.02 проходит прежнюю проверку (0.004), речи в записи нет.
        var state: UInt32 = 99
        let noise = (0..<(3 * 16_000)).map { _ -> Float in
            state = state &* 1_664_525 &+ 1_013_904_223
            return (Float(state >> 8) / Float(1 << 24) * 2 - 1) * 0.03
        }
        await dictate(rig, samples: noise, rms: 0.02)

        #expect(rig.engine.callCount == 0)
        #expect(rig.hud.last == .error(message: NSLocalizedString("dictation.emptyAudio", comment: "")))
        #expect(rig.delivery.inserted.isEmpty && rig.delivery.copied.isEmpty)
        #expect(try await savedItems(rig).isEmpty)
        #expect(rig.state.dictationPhase == .idle)
        #expect(rig.events.details(of: "dictation.noSpeech").count == 1)
    }

    @Test("удаление звука дожидается сохранения, которое ещё идёт")
    func deletionWaitsForPendingSave() async throws {
        let rig = try await makeRig(saveAudio: true)
        defer { rig.cleanup() }
        await rig.evaluation.setSaveDelay(.milliseconds(200))
        rig.audio.recording = Self.speech()
        rig.audio.recordingRMS = 0.07
        rig.state.handleHotkeyDown()
        rig.state.handleHotkeyDown()
        await rig.state.dictationTask?.value

        let removed = try await rig.state.deleteEvaluationAudio()

        #expect(removed == 1)
        #expect(await rig.evaluation.saved.isEmpty)
    }

    @Test("звук для оценки выключен — ничего не сохраняется")
    func evaluationAudioOffSavesNothing() async throws {
        let rig = try await makeRig(saveAudio: false)
        defer { rig.cleanup() }

        await dictate(rig, samples: Self.speech(), rms: 0.07)

        #expect(await rig.evaluation.saved.isEmpty)
    }

    @Test("звук для оценки включён — файл назван по записи в истории")
    func evaluationAudioOnSavesUnderTranscriptID() async throws {
        let rig = try await makeRig(saveAudio: true)
        defer { rig.cleanup() }
        let samples = Self.speech()

        await dictate(rig, samples: samples, rms: 0.07)

        let saved = await rig.evaluation.saved
        #expect(saved.count == 1)
        #expect(saved.first?.sampleCount == samples.count)
        #expect(saved.first?.id == (try await savedItems(rig)).first?.id)
    }

    @Test("запись без речи тоже сохраняется — по ней оценивают тишину")
    func evaluationAudioOnSavesRecordingsWithoutSpeech() async throws {
        let rig = try await makeRig(saveAudio: true)
        defer { rig.cleanup() }

        await dictate(rig, samples: Self.speech(seconds: 2, amplitude: 0.0005), rms: 0.0004)

        #expect(await rig.evaluation.saved.count == 1)
        #expect(try await savedItems(rig).isEmpty)
    }

    @Test("отказ сохранить звук не ломает диктовку и попадает в журнал")
    func evaluationAudioFailureDoesNotBreakDictation() async throws {
        let rig = try await makeRig(saveAudio: true)
        defer { rig.cleanup() }
        await rig.evaluation.setFailure(TranscribingError.underlying("диск полон"))

        await dictate(rig, samples: Self.speech(), rms: 0.07)

        #expect(rig.hud.last == .inserted)
        #expect(rig.events.details(of: "evaluationAudio.saveFailed").count == 1)
    }

    @Test("отменённая запись звука не оставляет")
    func cancelledRecordingLeavesNoEvaluationAudio() async throws {
        let rig = try await makeRig(saveAudio: true)
        defer { rig.cleanup() }
        rig.audio.recording = Self.speech()
        rig.audio.recordingRMS = 0.07

        rig.state.handleHotkeyDown()
        rig.state.cancelDictationFromHUD()

        #expect(await rig.evaluation.saved.isEmpty)
    }

    @Test("сводка и удаление идут через приложение")
    func summaryAndDeletionGoThroughTheApp() async throws {
        let rig = try await makeRig(saveAudio: true)
        defer { rig.cleanup() }
        await dictate(rig, samples: Self.speech(), rms: 0.07)

        #expect(await rig.state.evaluationAudioSummary().fileCount == 1)
        #expect(try await rig.state.deleteEvaluationAudio() == 1)
        #expect(await rig.state.evaluationAudioSummary().fileCount == 0)
    }

    @Test("микрофон сменился, запись продолжилась — запись идёт, плашка не меняется")
    func deviceChangeWithRestartKeepsRecording() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        rig.audio.recording = Self.speech()
        rig.audio.recordingRMS = 0.07
        rig.state.handleHotkeyDown()

        rig.audio.onInterruption?(.restarted)

        #expect(rig.state.dictationPhase == .recording)
        #expect(rig.engine.callCount == 0)
        #expect(rig.events.details(of: "capture.deviceChanged") == ["restarted"])
        if case .error = rig.hud.last { Issue.record("плашка показала ошибку") }
    }

    @Test("микрофон пропал посреди записи — сказанное не теряется")
    func deviceLossFinishesWithWhatWasRecorded() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        rig.audio.recording = Self.speech(seconds: 2)
        rig.audio.recordingRMS = 0.07
        rig.state.handleHotkeyDown()

        rig.audio.onInterruption?(.failed("устройство отключено"))
        await rig.state.dictationTask?.value

        #expect(rig.engine.callCount == 1)
        #expect(rig.delivery.inserted == ["Привет, мир."])
        #expect(rig.hud.last == .inserted)
        #expect(rig.state.dictationPhase == .idle)
        #expect(rig.events.details(of: "capture.deviceChanged").count == 1)
    }

    @Test("микрофон пропал, звука почти нет — ошибка микрофона, а не «пустая запись»")
    func deviceLossWithoutAudioShowsMicrophoneError() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        rig.audio.recording = Array(Self.speech().prefix(2_000))
        rig.audio.recordingRMS = 0.07
        rig.state.handleHotkeyDown()

        rig.audio.onInterruption?(.failed("устройство отключено"))

        #expect(rig.engine.callCount == 0)
        #expect(rig.hud.last == .error(
            message: NSLocalizedString("dictation.microphoneError", comment: ""),
            action: .selectMicrophone
        ))
        #expect(rig.state.dictationPhase == .idle)
        #expect(try await savedItems(rig).isEmpty)
    }

    @Test("прерывание без записи — ничего не происходит")
    func interruptionWithoutRecordingIsIgnored() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }

        rig.audio.onInterruption?(.failed("устройство отключено"))

        #expect(rig.state.dictationPhase == .idle)
        #expect(rig.hud.states.isEmpty)
        #expect(rig.engine.callCount == 0)
    }

    @Test("приложение не готово — запись не начинается, плашка называет причину")
    func notReadyAppRefusesToStartRecording() async throws {
        let rig = try await makeRig(ready: false)
        defer { rig.cleanup() }

        rig.state.handleHotkeyDown()

        #expect(rig.audio.startCount == 0)
        #expect(rig.audio.isCapturing == false)
        #expect(rig.engine.callCount == 0)
        #expect(rig.hud.last == .error(
            message: NSLocalizedString(rig.state.readiness.state.statusLocalizationKey, comment: "")
        ))
        #expect(rig.state.dictationPhase == .idle)
    }

    // MARK: - Удачная ветка

    @Test("речь распознаётся, вставляется и сохраняется в историю")
    func speechIsRecognisedDeliveredAndSaved() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }

        await dictate(rig, samples: Self.speech(), rms: 0.07)

        #expect(rig.engine.callCount == 1)
        #expect(rig.delivery.inserted == ["Привет, мир."])
        #expect(rig.hud.last == .inserted)
        let saved = try await savedItems(rig)
        #expect(saved.count == 1)
        #expect(saved.first?.source == .dictation)
        #expect(saved.first?.insertionOutcome == .inserted)
        #expect(saved.first?.language == "ru")
        #expect(saved.first?.createdAt == Int64(Self.fixedNow.timeIntervalSince1970 * 1_000))
        #expect(rig.state.dictationPhase == .idle)
    }

    @Test("вставка не удалась — текст остаётся в буфере, исход «скопировано»")
    func refusedPasteLeavesTextCopied() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        rig.delivery.outcome = .copied

        await dictate(rig, samples: Self.speech(), rms: 0.07)

        #expect(rig.hud.last == .copied)
        #expect(try await savedItems(rig).first?.insertionOutcome == .copied)
    }

    @Test("автовставка выключена — текст только в буфере, не потерян")
    func autoInsertOffCopiesInsteadOfPasting() async throws {
        let rig = try await makeRig(autoInsert: false)
        defer { rig.cleanup() }

        await dictate(rig, samples: Self.speech(), rms: 0.07)

        #expect(rig.delivery.inserted.isEmpty)
        #expect(rig.delivery.copied == ["Привет, мир."])
        #expect(rig.hud.last == .copied)
    }

    // MARK: - Отказ

    @Test("отказ распознавания — ошибка на плашке, ничего не вставлено и не сохранено")
    func recognitionFailureShowsErrorAndKeepsNothing() async throws {
        let rig = try await makeRig(engineResult: .failure(TranscribingError.underlying("boom")))
        defer { rig.cleanup() }

        await dictate(rig, samples: Self.speech(), rms: 0.07)

        #expect(rig.hud.last == .error(message: NSLocalizedString("dictation.transcriptionFailed", comment: "")))
        #expect(rig.delivery.inserted.isEmpty && rig.delivery.copied.isEmpty)
        #expect(try await savedItems(rig).isEmpty)
        #expect(rig.state.dictationPhase == .idle)
    }
}
