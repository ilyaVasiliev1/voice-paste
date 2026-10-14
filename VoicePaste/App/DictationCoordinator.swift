import Foundation

/// То, что координатору диктовки нужно от приложения: показать окно, сообщить
/// фазу и спросить, не идёт ли лекция. Узкий шов вместо ссылки на `AppState`.
@MainActor
protocol DictationHost: AnyObject {
    var isLectureRecording: Bool { get }
    func presentHUD(_ state: HUDState)
    func dictationPhaseChanged(_ phase: DictationPhase)
    func setEscapeCancellationEnabled(_ isEnabled: Bool)
    func stopLectureAfterMicrophoneLoss()
}

/// Ведёт одну диктовку от горячей клавиши до вставленного текста: конечный
/// автомат режимов, запись, таймеры окна, пауза по Escape, остановка и
/// доставка. Распознавание и приведение текста — в `DictationPipeline`.
@MainActor
final class DictationCoordinator {
    private var stateMachine: DictationStateMachine
    private let settings: AppSettings
    private let modelManager: ModelManager
    private let historyStore: any HistoryStoring
    private let readiness: ReadinessCoordinator
    private let audioCapture: any AudioSource
    private let textDelivery: any TextDelivering
    private let hud: any HUDPresenting
    private let now: () -> Date
    private let isDictationReady: (@MainActor () -> Bool)?
    private let logEvent: @Sendable (String, String) -> Void
    private let evaluationAudio: any EvaluationAudioStoring
    private let pipeline: DictationPipeline
    private let streamingTranscriber = StreamingDictationTranscriber(
        windowSamples: 28 * 16_000,
        overlapSamples: Int(0.75 * 16_000)
    )

    weak var host: (any DictationHost)?

    private(set) var evaluationAudioTask: Task<Void, Never>?
    private(set) var dictationTask: Task<Void, Never>?
    private var frontAppSnapshot: FrontAppSnapshot?
    private var recordingStartedAt: Date?
    private var elapsedBeforePause: TimeInterval = 0
    private var isPaused = false
    private var elapsedTimerTask: Task<Void, Never>?
    private var pausedExpiryTask: Task<Void, Never>?
    /// Both the audio meter (10 Hz) and elapsed timer (5 Hz) ask to refresh
    /// the same HUD. Coalescing guarantees one lightweight SwiftUI update at
    /// most every 100 ms instead of occasionally painting twice in one tick.
    private var lastRecordingHUDRefreshAt = Date.distantPast
    private var currentLevel: Float = 0

    init(
        settings: AppSettings,
        modelManager: ModelManager,
        historyStore: any HistoryStoring,
        readiness: ReadinessCoordinator,
        audioCapture: any AudioSource,
        textDelivery: any TextDelivering,
        hud: any HUDPresenting,
        now: @escaping () -> Date,
        isDictationReady: (@MainActor () -> Bool)?,
        logEvent: @escaping @Sendable (String, String) -> Void,
        evaluationAudio: any EvaluationAudioStoring,
        pipeline: DictationPipeline
    ) {
        self.settings = settings
        self.modelManager = modelManager
        self.historyStore = historyStore
        self.readiness = readiness
        self.audioCapture = audioCapture
        self.textDelivery = textDelivery
        self.hud = hud
        self.now = now
        self.isDictationReady = isDictationReady
        self.logEvent = logEvent
        self.evaluationAudio = evaluationAudio
        self.pipeline = pipeline
        self.stateMachine = DictationStateMachine(mode: settings.recordingMode)
    }

    var phase: DictationPhase { stateMachine.phase }
    var isDictationPaused: Bool { isPaused }

    func recordingModeChanged() {
        stateMachine.mode = settings.recordingMode
    }

    func audioLevelChanged(_ level: Float) {
        currentLevel = level
        refreshRecordingHUD()
    }

    // MARK: - Hotkey / toggle+hold state machine (L-002/L-003, EC-003)

    func handleHotkeyDown() {
        if isPaused {
            resumeAfterEscape()
            return
        }
        if stateMachine.phase == .idle, !isReadyToDictate {
            presentNotReadyMessage()
            return
        }
        apply(stateMachine.handleHotkeyDown())
    }

    func handleHotkeyUp() {
        guard !isPaused else { return }
        apply(stateMachine.handleHotkeyUp())
    }

    func finishFromHUD() {
        apply(stateMachine.finishFromUI())
    }

    func cancelFromHUD() {
        apply(stateMachine.cancelFromUI())
    }

    private func apply(_ effect: DictationEffect) {
        switch effect {
        case .startCapture:
            beginRecording()
        case .stopCaptureAndProcess:
            endRecordingAndProcess()
        case .cancelCapture:
            cancelRecording()
        case .alreadyProcessing:
            // EC-003: keep the running job, just say so.
            host?.presentHUD(.error(
                message: NSLocalizedString("dictation.alreadyProcessing", comment: "")
            ))
        case .none:
            break
        }
        synchronizePhase()
    }

    private var isReadyToDictate: Bool {
        isDictationReady?() ?? (readiness.state == .ready)
    }

    private func presentNotReadyMessage() {
        // Logged with the *reason*, not just "an error appeared": this plaque
        // is what the user actually sees when dictation refuses to start, and
        // without the readiness state behind it the log said nothing useful.
        Task {
            await DiagnosticLog.shared.log(
                "dictation.notReady",
                detail: ReadinessCoordinator.describe(readiness.state)
            )
        }
        host?.presentHUD(.error(
            message: NSLocalizedString(readiness.state.statusLocalizationKey, comment: "")
        ))
    }

    private func synchronizePhase() {
        host?.dictationPhaseChanged(stateMachine.phase)
        host?.setEscapeCancellationEnabled(stateMachine.phase == .recording && !isPaused)
    }

    // MARK: - Recording (L-004, DEP-003)

    private func beginRecording() {
        // Микрофон и накопитель в приложении одни. Если идёт лекция, старт
        // диктовки не «добавляет вторую запись», а рушит обе: `start()` молча
        // возвращается на уже идущем захвате, а последующий `stop()` выгребает
        // буфер лекции себе. Прежде это проходило без единой ошибки на экране,
        // и лекция продолжала выглядеть записывающейся при остановленном
        // микрофоне.
        guard host?.isLectureRecording != true else {
            stateMachine.handleProcessingFinished()
            host?.dictationPhaseChanged(.idle)
            host?.presentHUD(.error(message: NSLocalizedString("dictation.busyWithLecture", comment: "")))
            Task { await DiagnosticLog.shared.log("dictation.refused.lectureRecording") }
            return
        }
        frontAppSnapshot = textDelivery.captureFrontApp()
        // `L-010`: start loading the model the moment recording begins, so it
        // warms up *while the user is still speaking* if the one-time launch
        // warm-up has not completed (or the model was later unloaded).
        // `ensureLoaded()` coalesces, so the transcription that follows joins
        // this same load rather than starting a second one.
        modelManager.prewarm()
        do {
            try audioCapture.start()
        } catch {
            stateMachine.handleProcessingFinished()
            host?.dictationPhaseChanged(.idle)
            // `dictation.microphoneError`'s single relevant recovery is
            // picking a working input device in Settings → Разрешения.
            host?.presentHUD(.error(
                message: NSLocalizedString("dictation.microphoneError", comment: ""),
                action: .selectMicrophone
            ))
            Task { await DiagnosticLog.shared.log("capture.start.failed", detail: String(describing: error)) }
            streamingTranscriber.cancel()
            return
        }
        recordingStartedAt = now()
        elapsedBeforePause = 0
        isPaused = false
        pausedExpiryTask?.cancel()
        // Present synchronously after successful capture. The ticker is only
        // for subsequent elapsed/level updates; waiting for its task turn
        // made the HUD vulnerable to being visually missed under load.
        refreshRecordingHUD(force: true)
        startElapsedTicker()
        startStreamingTranscription()
    }

    /// Поднимает счёт окон по ходу записи, дождавшись модели.
    ///
    /// Ждать асинхронно, а не проверять «уже ли она в памяти»: после
    /// перезапуска или выгрузки по нехватке памяти модель не резидентна, и
    /// проверка молча отменяла бы весь параллельный счёт. `ensureLoaded()`
    /// объединяет вызовы с идущим прогревом, так что второй загрузки не
    /// будет.
    private func startStreamingTranscription() {
        streamingTranscriber.cancel()
        Task { [weak self] in
            guard let self, let engine = try? await modelManager.ensureLoaded() else { return }
            // Пока модель грузилась, запись могли остановить или отменить.
            guard stateMachine.phase == .recording else { return }
            streamingTranscriber.begin(
                transcriber: engine,
                language: settings.languageMode,
                availableSamples: { [audioCapture] in audioCapture.capturedSampleCount },
                readSamples: { [audioCapture] range in audioCapture.capturedSamples(in: range) }
            )
        }
    }

    private func startElapsedTicker() {
        elapsedTimerTask?.cancel()
        elapsedTimerTask = Task { [weak self] in
            while let self, self.stateMachine.phase == .recording, !Task.isCancelled {
                self.refreshRecordingHUD()
                // TOK-hud.recording-updates — не более десяти обновлений в секунду.
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func refreshRecordingHUD(force: Bool = false) {
        guard stateMachine.phase == .recording,
              !isPaused,
              let startedAt = recordingStartedAt else { return }
        let now = self.now()
        guard force || now.timeIntervalSince(lastRecordingHUDRefreshAt) >= 0.1 else { return }
        lastRecordingHUDRefreshAt = now
        host?.presentHUD(.recording(
            elapsed: elapsedBeforePause + now.timeIntervalSince(startedAt),
            level: currentLevel
        ))
    }

    /// `UI-003` HUD "Отменить" button (mode-independent, works alongside the
    /// hotkey): stops capture and discards the buffer outright — no
    /// transcription is ever started and no history row is written, unlike
    /// `endRecordingAndProcess()`.
    private func cancelRecording(showUndo: Bool = false) {
        discardRecording()
        host?.presentHUD(showUndo ? .cancelledWithUndo : .cancelled)
    }

    private func discardRecording() {
        elapsedTimerTask?.cancel()
        pausedExpiryTask?.cancel()
        // Посчитанные по ходу окна выбрасываются вместе с буфером: отменённая
        // запись не оставляет следов.
        streamingTranscriber.cancel()
        _ = audioCapture.stop() // discarded on purpose: cancel means no transcription, no history
        frontAppSnapshot = nil
        recordingStartedAt = nil
        elapsedBeforePause = 0
        isPaused = false
        currentLevel = 0
        lastRecordingHUDRefreshAt = .distantPast
    }

    /// Escape pauses capture without draining its buffer. The return arrow
    /// resumes into the same accumulator; only the explicit × control truly
    /// discards a recording.
    func cancelWithEscape() {
        guard stateMachine.phase == .recording, !isPaused else { return }
        elapsedTimerTask?.cancel()
        if let recordingStartedAt {
            elapsedBeforePause += now().timeIntervalSince(recordingStartedAt)
        }
        self.recordingStartedAt = nil
        audioCapture.pause()
        isPaused = true
        host?.setEscapeCancellationEnabled(false)
        host?.presentHUD(.cancelledWithUndo)
        pausedExpiryTask?.cancel()
        pausedExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.cancelPausedFromHUD()
        }
    }

    /// File mode is a true mode switch: current microphone audio is discarded
    /// and the capture engine is stopped before the drop target is shown.
    func discardForFileImport() {
        guard stateMachine.phase == .recording else { return }
        _ = stateMachine.cancelFromUI()
        synchronizePhase()
        discardRecording()
    }

    /// The curved-arrow control after Escape reconnects a fresh mic engine
    /// to the existing accumulator, preserving everything said before pause.
    func resumeAfterEscape() {
        guard stateMachine.phase == .recording, isPaused else { return }
        do {
            try audioCapture.resume()
            isPaused = false
            pausedExpiryTask?.cancel()
            recordingStartedAt = now()
            host?.setEscapeCancellationEnabled(true)
            refreshRecordingHUD(force: true)
            startElapsedTicker()
        } catch {
            _ = stateMachine.cancelFromUI()
            synchronizePhase()
            discardRecording()
            host?.presentHUD(.error(
                message: NSLocalizedString("dictation.microphoneError", comment: ""),
                action: .selectMicrophone
            ))
        }
    }

    /// The × shown while Escape-paused is the irreversible branch: discard
    /// all captured audio and return to idle. It is deliberately distinct
    /// from the curved return arrow, which resumes the same buffer.
    func cancelPausedFromHUD() {
        guard stateMachine.phase == .recording, isPaused else { return }
        _ = stateMachine.cancelFromUI()
        synchronizePhase()
        cancelRecording()
    }

    // MARK: - Stop + transcribe (L-005/L-006/L-007/L-008, EC-004/EC-005)

    private func endRecordingAndProcess() {
        elapsedTimerTask?.cancel()
        let samples = audioCapture.stop()
        // Имя файла звука — id записи в истории: звук и расшифровка находятся друг по другу.
        let recordingID = UUID()
        saveEvaluationAudioIfEnabled(samples, id: recordingID)

        // Слишком короткая или тихая запись отвергается до модели и до показа
        // «обработка»: окно сразу сменяется ошибкой, без промежуточного вида.
        // Громкость посчитана при захвате, а не вторым проходом по буферу.
        guard pipeline.admitCapture(sampleCount: samples.count, captureRMS: audioCapture.lastCaptureRMS) == nil else {
            stateMachine.handleProcessingFinished()
            host?.dictationPhaseChanged(.idle)
            host?.presentHUD(.error(
                message: NSLocalizedString("dictation.emptyAudio", comment: "")
            ))
            return
        }

        dictationTask = Task { [weak self] in
            await self?.transcribeAndFinish(samples: samples, recordingID: recordingID)
        }
    }

    private func transcribeAndFinish(samples: [Float], recordingID: UUID) async {
        defer {
            stateMachine.handleProcessingFinished()
            host?.dictationPhaseChanged(.idle)
            frontAppSnapshot = nil
        }

        do {
            let vocabulary = (try? await historyStore.fetchVocabulary()) ?? []
            let language = settings.languageMode
            let outcome = try await pipeline.run(
                samples: samples,
                language: language,
                vocabulary: vocabulary,
                autoCorrectSafeTypos: settings.autoCorrectSafeTypos,
                recognizer: LiveRecognizer(modelManager: modelManager, streaming: streamingTranscriber),
                onSpeechConfirmed: { @MainActor [weak self] in self?.host?.presentHUD(.processing) }
            )
            switch outcome {
            case .rejected:
                streamingTranscriber.cancel()
                logEvent("dictation.noSpeech", "durationMs=\(samples.count * 1_000 / 16_000)")
                host?.presentHUD(.error(message: NSLocalizedString("dictation.emptyAudio", comment: "")))
            case .draft(let draft):
                await deliver(draft, language: language, recordingID: recordingID)
            }
        } catch {
            modelManager.endTask(unloadMinutes: settings.modelUnloadMinutes)
            host?.presentHUD(.error(
                message: NSLocalizedString("dictation.transcriptionFailed", comment: "")
            ))
            Task { await DiagnosticLog.shared.log("dictation.transcriptionFailed", detail: String(describing: error)) }
        }
    }

    private func deliver(_ draft: Draft, language: TranscriptionLanguage, recordingID: UUID) async {
        logEvent("dictation.language", DictationLanguageJournal.detail(
            mode: language,
            detected: draft.detectedLanguage,
            text: draft.rawText,
            durationMilliseconds: draft.durationMilliseconds
        ))

        var outcome: Transcript.InsertionOutcome = .notRequested
        if settings.autoInsertEnabled {
            outcome = textDelivery.insert(draft.text, into: frontAppSnapshot) == .inserted ? .inserted : .copied
        } else {
            // "Не вставлять автоматически" is a deliberate clipboard
            // workflow, never a silent discard of the finished text.
            textDelivery.copyToClipboard(draft.text)
            outcome = .copied
        }

        let stamp = Int64(now().timeIntervalSince1970 * 1_000)
        let transcript = Transcript(
            id: recordingID,
            createdAt: stamp,
            updatedAt: stamp,
            source: .dictation,
            sourceFileName: nil,
            durationMilliseconds: draft.durationMilliseconds,
            language: draft.detectedLanguage,
            rawText: draft.rawText,
            text: draft.text,
            preview: Transcript.makePreview(from: draft.text),
            status: .completed,
            insertionOutcome: outcome
        )

        if settings.historyEnabled {
            do {
                try await historyStore.save(transcript)
            } catch {
                // Текст уже вставлен или лежит в буфере, поэтому отказ
                // хранилища не отменяет удачную диктовку и HUD остаётся
                // прежним. Но молчать о нём нельзя: причина отказа
                // сохраняется без текста расшифровки.
                Task {
                    await DiagnosticLog.shared.log(
                        "dictation.historySaveFailed",
                        detail: String(describing: error)
                    )
                }
            }
        }
        modelManager.endTask(unloadMinutes: settings.modelUnloadMinutes)

        switch outcome {
        case .inserted: host?.presentHUD(.inserted)
        case .copied: host?.presentHUD(.copied)
        case .notRequested: host?.presentHUD(.hidden)
        }
    }

    // MARK: - Смена микрофона

    func handleCaptureInterruption(_ event: AudioCaptureInterruption) {
        switch event {
        case .restarted:
            logEvent("capture.deviceChanged", "restarted")
        case .failed(let reason):
            logEvent("capture.deviceChanged", "failed reason=\(reason)")
            if host?.isLectureRecording == true {
                host?.stopLectureAfterMicrophoneLoss()
                return
            }
            guard stateMachine.phase == .recording, !isPaused else { return }
            if audioCapture.capturedSampleCount >= DictationPipeline.minimumSamples {
                finishFromHUD()
            } else {
                _ = stateMachine.cancelFromUI()
                discardRecording()
                synchronizePhase()
                host?.presentHUD(.error(
                    message: NSLocalizedString("dictation.microphoneError", comment: ""),
                    action: .selectMicrophone
                ))
            }
        }
    }

    // MARK: - Звук для оценки

    private func saveEvaluationAudioIfEnabled(_ samples: [Float], id: UUID) {
        guard settings.saveAudioForEvaluation, !samples.isEmpty else { return }
        let store = evaluationAudio
        let log = logEvent
        evaluationAudioTask = Task {
            do {
                try await store.save(samples: samples, id: id)
            } catch {
                log("evaluationAudio.saveFailed", ErrorSummary.describe(error))
            }
        }
    }

    func evaluationAudioSummary() async -> EvaluationAudioSummary {
        await evaluationAudio.summary()
    }

    func deleteEvaluationAudio() async throws -> Int {
        // WHY: идущее сохранение иначе обогнало бы удаление и пережило его.
        await evaluationAudioTask?.value
        return try await evaluationAudio.deleteAll()
    }
}

/// Распознавание диктовки: загрузить модель и досчитать хвост поверх окон,
/// посчитанных по ходу записи.
@MainActor
private final class LiveRecognizer: Recognizing {
    private let modelManager: ModelManager
    private let streaming: StreamingDictationTranscriber

    init(modelManager: ModelManager, streaming: StreamingDictationTranscriber) {
        self.modelManager = modelManager
        self.streaming = streaming
    }

    func recognize(samples: [Float], language: TranscriptionLanguage) async throws -> TranscriptionResult {
        let engine = try await modelManager.ensureLoaded()
        return try await streaming.finish(transcriber: engine, language: language, totalSamples: samples)
    }
}
