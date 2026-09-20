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
        Task { [weak self] in
            guard let self else { return }
            let engine: any Transcribing
            do {
                engine = try await modelManager.ensureLoaded()
            } catch {
                await DiagnosticLog.shared.log(
                    "lecture.liveTranscriptionUnavailable",
                    detail: String(describing: error)
                )
                return
            }
            // Пока модель грузилась, запись могли остановить.
            guard isLectureRecording else { return }
            lectureRecorder.begin(
                transcriber: engine,
                language: settings.languageMode,
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

        let paragraphs: [LectureParagraph]
        if let engine = try? await modelManager.ensureLoaded() {
            paragraphs = await lectureRecorder.finish(
                transcriber: engine,
                language: settings.languageMode,
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
        guard let lectureStore, !paragraphs.isEmpty else { return }
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
