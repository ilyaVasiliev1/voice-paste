import AppKit
import Foundation

// MARK: - Учебный режим

extension AppState {

    /// Начинает или останавливает запись лекции.
    ///
    /// Вынесено расширением: учебный режим — отдельная работа со своей
    /// нарезкой и своим хранилищем, и мешать её с диктовкой в теле типа
    /// значило бы усложнять и без того самый нагруженный путь.
    public func toggleLectureRecording() {
        if isLectureRecording {
            Task { await finishLectureRecording() }
        } else {
            beginLectureRecording()
        }
    }

    /// Дописывает открытую сохранённую лекцию новой записью: абзацы встанут в
    /// её конец со временем от её конца (`LectureContinuation`).
    public func continueOpenedLecture() {
        guard !isLectureRecording, let opened = openedLecture else { return }
        continuingLectureID = opened.lecture.id
        beginLectureRecording()
        // Запись не началась (занят микрофон, идёт диктовка) — и продолжения нет.
        if !isLectureRecording { continuingLectureID = nil }
    }

    private func beginLectureRecording() {
        guard !isLectureRecording else { return }
        // Обратный запрет — в `beginRecording()`. Здесь отказ объясняется:
        // молча неработающая кнопка хуже честного отказа.
        guard dictationPhase == .idle else {
            presentHUD(.error(message: NSLocalizedString("lecture.busyWithDictation", comment: "")))
            return
        }
        lectureRecorder.cancel()
        do {
            try audioCapture.start()
        } catch {
            presentHUD(.error(
                message: NSLocalizedString("dictation.microphoneError", comment: ""),
                action: .selectMicrophone
            ))
            Task { await DiagnosticLog.shared.log("lecture.start.failed", detail: String(describing: error)) }
            return
        }
        isLectureRecording = true
        lectureStartedAt = Date()
        lectureElapsedSeconds = 0
        startLectureTicker()

        startLectureTranscription()
    }

    /// Поднимает живой счёт окон, дождавшись модели.
    ///
    /// Прежде здесь стояла проверка «модель уже в памяти — иначе выходим», и
    /// это убивало весь режим: после перезапуска или выгрузки по нехватке
    /// памяти модель не резидентна, живой счёт молча не начинался, и вся
    /// лекция распознавалась одним куском только после остановки. Ровно то,
    /// что владелец и увидел.
    ///
    /// Ждать модель нужно асинхронно: запись уже идёт, звук копится, и к
    /// моменту готовности первые окна будут посчитаны разом.
    private func startLectureTranscription() {
        let language = settings.lectureLanguage
        if activeLectureEngine == .system, #available(macOS 26.0, *) {
            startSystemLectureTranscription(language: language)
        } else {
            startWhisperLectureTranscription(language: language)
        }
    }

    /// Движок для этой лекции: выбранный владельцем, а если он не выбирал —
    /// разумный для языка. Система до macOS 26 его не знает вовсе.
    var activeLectureEngine: LectureEngine {
        settings.lectureEngine ?? LectureEngine.default(for: settings.lectureLanguage)
    }

    @available(macOS 26.0, *)
    private func startSystemLectureTranscription(language: TranscriptionLanguage) {
        let recorder = SystemLiveTranscriber()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await lectureRecorder.beginStreaming(
                    engine: recorder,
                    language: language,
                    pauseSeconds: settings.lectureParagraphPauseSeconds
                )
            } catch {
                // Язык, которого система не знает, или отказ подготовки —
                // не повод остаться без расшифровки. Уходим на Whisper.
                await DiagnosticLog.shared.log(
                    "lecture.systemEngineUnavailable",
                    detail: String(describing: error)
                )
                startWhisperLectureTranscription(language: language)
                return
            }
            guard isLectureRecording else { return }
            // Звук подаётся по ходу. Замыкание зовётся с аудиопотока, поэтому
            // переход на главный актор здесь, а не у получателя.
            audioCapture.onAudioChunk = { [weak self] chunk in
                Task { @MainActor in self?.lectureRecorder.appendStreamingAudio(chunk) }
            }
        }
    }

    private func startWhisperLectureTranscription(language: TranscriptionLanguage) {
        Task { [weak self] in
            guard let self else { return }
            guard let engine = try? await modelManager.ensureLoaded() else {
                await DiagnosticLog.shared.log("lecture.liveTranscriptionUnavailable")
                return
            }
            guard isLectureRecording else { return }
            lectureRecorder.begin(
                transcriber: engine,
                language: language,
                pauseSeconds: settings.lectureParagraphPauseSeconds,
                availableSamples: { [audioCapture] in audioCapture.capturedSampleCount },
                readSamples: { [audioCapture] range in audioCapture.capturedSamples(in: range) }
            )
        }
    }

    private func finishLectureRecording() async {
        guard isLectureRecording else { return }
        isLectureRecording = false
        lectureTimerTask?.cancel()
        let samples = audioCapture.stop()
        let startedAt = lectureStartedAt ?? Date()
        lectureStartedAt = nil

        audioCapture.onAudioChunk = nil
        let paragraphs: [LectureParagraph]
        if activeLectureEngine == .system, #available(macOS 26.0, *) {
            // Потоковому движку досчитывать нечего: он шёл вровень с речью.
            paragraphs = await lectureRecorder.finishStreaming()
        } else if let engine = try? await modelManager.ensureLoaded() {
            paragraphs = await lectureRecorder.finish(
                transcriber: engine,
                language: settings.lectureLanguage,
                totalSamples: samples
            )
        } else {
            // Модель не поднялась — хвост досчитать нечем. Но всё, что уже
            // распозналось за лекцию, лежит на экране и обязано быть
            // сохранено: иначе час прослушанного исчезнет при следующем
            // старте, когда `cancel()` очистит абзацы. Отказ виден, а не
            // только в журнале.
            paragraphs = lectureRecorder.paragraphs
            presentHUD(.error(message: NSLocalizedString("lecture.tailNotTranscribed", comment: "")))
            await DiagnosticLog.shared.log("lecture.finish.noModel")
        }
        await persistLecture(paragraphs: paragraphs, startedAt: startedAt, samples: samples.count)
    }

    private func persistLecture(paragraphs: [LectureParagraph], startedAt: Date, samples: Int) async {
        let continuingID = continuingLectureID
        continuingLectureID = nil
        guard let lectureStore, !paragraphs.isEmpty else { return }
        if let continuingID, let opened = openedLecture, opened.lecture.id == continuingID {
            await persistContinuation(of: opened, paragraphs: paragraphs, samples: samples, in: lectureStore)
            return
        }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let id = UUID()
        let detail = LectureDetail(
            lecture: Lecture(
                id: id,
                createdAt: Int64(startedAt.timeIntervalSince1970 * 1_000),
                updatedAt: now,
                title: Lecture.defaultTitle(startedAt: startedAt, formatter: Self.lectureTitleFormatter),
                durationMilliseconds: samples * 1_000 / 16_000,
                language: lectureRecorder.detectedLanguage,
                wordCount: WordCounting.count(in: paragraphs.map(\.text).joined(separator: " "))
            ),
            paragraphs: paragraphs.enumerated().map { index, paragraph in
                StoredLectureParagraph(
                    id: UUID(),
                    lectureID: id,
                    orderIndex: index,
                    startMilliseconds: Int(paragraph.startSeconds * 1_000),
                    endMilliseconds: Int(paragraph.endSeconds * 1_000),
                    text: paragraph.text
                )
            }
        )
        do {
            try await lectureStore.save(detail)
            await refreshSavedLectures()
            // Записанная лекция сразу открыта и выбрана в списке: её
            // расшифровка остаётся на экране, но уже как сохранённая, со своей
            // строкой — а не как ничья копия под строкой новой лекции.
            openedLecture = detail
            lectureRecorder.cancel()
        } catch {
            // Лекция уже на экране и никуда не делась — отказ хранилища не
            // отменяет прослушанного. Но молчать о нём нельзя: это ровно та
            // потеря, которую иначе замечают через неделю.
            await DiagnosticLog.shared.log(
                "lecture.saveFailed",
                detail: String(describing: error)
            )
        }
    }

    private func persistContinuation(
        of opened: LectureDetail,
        paragraphs: [LectureParagraph],
        samples: Int,
        in lectureStore: any LectureStoring
    ) async {
        let continued = LectureContinuation.appending(
            paragraphs,
            recordedMilliseconds: samples * 1_000 / 16_000,
            to: opened,
            now: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        do {
            try await lectureStore.save(continued)
            await refreshSavedLectures()
            openedLecture = continued
            lectureRecorder.cancel()
        } catch {
            // Дописанное остаётся на экране в записывающем — отказ виден в
            // журнале, как и при сохранении новой лекции.
            await DiagnosticLog.shared.log(
                "lecture.continueSaveFailed",
                detail: String(describing: error)
            )
        }
    }

    // MARK: - Сохранённые лекции

    /// Перечитывает список сохранённых лекций.
    public func refreshSavedLectures() async {
        guard let lectureStore else { return }
        do {
            savedLectures = try await lectureStore.fetchAll()
        } catch {
            await DiagnosticLog.shared.log(
                "lecture.listFailed",
                detail: String(describing: error)
            )
        }
    }

    /// Открывает сохранённую лекцию для чтения. Идущую запись не трогает:
    /// открыть чужую лекцию посреди своей — верный способ потерять её.
    public func openSavedLecture(id: UUID) async {
        guard !isLectureRecording, let lectureStore else { return }
        do {
            guard let detail = try await lectureStore.fetchDetail(id: id) else { return }
            openedLecture = detail
        } catch {
            await DiagnosticLog.shared.log(
                "lecture.openFailed",
                detail: String(describing: error)
            )
        }
    }

    public func closeOpenedLecture() {
        // Продолжаемую лекцию не закрыть посреди записи: дописывать было бы
        // некуда, и запись ушла бы в новую лекцию.
        guard continuingLectureID == nil else { return }
        openedLecture = nil
    }

    public func renameLecture(id: UUID, title: String) async {
        guard let lectureStore else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await lectureStore.rename(
                id: id,
                title: trimmed,
                updatedAt: Int64(Date().timeIntervalSince1970 * 1_000)
            )
            await refreshSavedLectures()
            if openedLecture?.lecture.id == id { openedLecture?.lecture.title = trimmed }
        } catch {
            await DiagnosticLog.shared.log(
                "lecture.renameFailed",
                detail: String(describing: error)
            )
        }
    }

    public func deleteLecture(id: UUID) async {
        guard let lectureStore else { return }
        do {
            try await lectureStore.delete(id: id)
            if openedLecture?.lecture.id == id { openedLecture = nil }
            await refreshSavedLectures()
        } catch {
            await DiagnosticLog.shared.log(
                "lecture.deleteFailed",
                detail: String(describing: error)
            )
        }
    }

    private func startLectureTicker() {
        lectureTimerTask?.cancel()
        lectureTimerTask = Task { [weak self] in
            while let self, self.isLectureRecording, !Task.isCancelled {
                if let startedAt = self.lectureStartedAt {
                    self.lectureElapsedSeconds = Date().timeIntervalSince(startedAt)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private static let lectureTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
