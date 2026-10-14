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

    // MARK: - Подставные части

    @MainActor
    final class FakeAudioSource: AudioSource {
        var isCapturing = false
        var lastCaptureRMS: Float = 0
        var capturedSampleCount: Int { recording.count }
        var onLevel: ((Float) -> Void)?
        var onAudioChunk: (@Sendable ([Float]) -> Void)?
        var recording: [Float] = []
        var recordingRMS: Float = 0
        private(set) var startCount = 0

        func start() throws {
            startCount += 1
            isCapturing = true
        }
        func resume() throws { isCapturing = true }
        func pause() { isCapturing = false }
        func stop() -> [Float] {
            isCapturing = false
            lastCaptureRMS = recordingRMS
            return recording
        }
        func capturedSamples(in range: Range<Int>) -> [Float] {
            Array(recording[range.clamped(to: 0..<recording.count)])
        }
    }

    @MainActor
    final class FakeTextDelivery: TextDelivering {
        var outcome: InsertionOutcome = .inserted
        private(set) var inserted: [String] = []
        private(set) var copied: [String] = []
        func captureFrontApp() -> FrontAppSnapshot? {
            FrontAppSnapshot(bundleIdentifier: "test.app", processIdentifier: 1)
        }
        func insert(_ text: String, into snapshot: FrontAppSnapshot?) -> InsertionOutcome {
            inserted.append(text)
            return outcome
        }
        func copyToClipboard(_ text: String) { copied.append(text) }
    }

    @MainActor
    final class FakeHUD: HUDPresenting {
        private(set) var states: [HUDState] = []
        func present(_ state: HUDState) { states.append(state) }
        func hide() { states.append(.hidden) }
        var last: HUDState? { states.last }
    }

    /// Вызовы модели считаются под замком: распознавание идёт вне главного актора.
    final class CountingTranscriber: Transcribing, @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [TranscriptionRequest] = []
        var result: Result<TranscriptionResult, Error>

        init(result: Result<TranscriptionResult, Error>) { self.result = result }

        var callCount: Int { lock.withLock { requests.count } }

        func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
            lock.withLock { requests.append(request) }
            return try result.get()
        }
    }

    /// Журнал событий под замком: запись приходит с фоновой задачи.
    final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(event: String, detail: String)] = []

        func append(_ event: String, _ detail: String) {
            lock.withLock { entries.append((event, detail)) }
        }

        func details(of event: String) -> [String] {
            lock.withLock { entries.filter { $0.event == event }.map(\.detail) }
        }
    }

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
        let cleanup: () -> Void
    }

    static let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    func makeRig(
        engineResult: Result<TranscriptionResult, Error> = .success(
            TranscriptionResult(rawText: "Привет, мир.", detectedLanguage: "ru")
        ),
        autoInsert: Bool = true,
        ready: Bool = true
    ) async throws -> Rig {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationTract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let defaults = UserDefaults(suiteName: "DictationTract-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.autoInsertEnabled = autoInsert
        settings.historyEnabled = true

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
            logEvent: { events.append($0, $1) }
        )
        return Rig(
            state: state, audio: audio, delivery: delivery, hud: hud,
            engine: engine, store: store, settings: settings, events: events,
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
