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
        guard !isLectureRecording, dictationPhase == .idle else { return }
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

        // Модель берётся уже загруженной: грузить её во время лекции нельзя,
        // а прогрев идёт своим чередом. Не успела — окна не считаются, и
        // расшифровка появится после остановки.
        modelManager.prewarm()
        guard let engine = modelManager.loadedTranscriber else { return }
        lectureRecorder.begin(
            transcriber: engine,
            language: settings.languageMode,
            pauseSeconds: settings.lectureParagraphPauseSeconds,
            availableSamples: { [audioCapture] in audioCapture.capturedSampleCount },
            readSamples: { [audioCapture] range in audioCapture.capturedSamples(in: range) }
        )
    }

    private func finishLectureRecording() async {
        guard isLectureRecording else { return }
        isLectureRecording = false
        lectureTimerTask?.cancel()
        let samples = audioCapture.stop()
        let startedAt = lectureStartedAt ?? Date()
        lectureStartedAt = nil

        guard let engine = try? await modelManager.ensureLoaded() else {
            await DiagnosticLog.shared.log("lecture.finish.noModel")
            return
        }
        let paragraphs = await lectureRecorder.finish(
            transcriber: engine,
            language: settings.languageMode,
            totalSamples: samples
        )
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
