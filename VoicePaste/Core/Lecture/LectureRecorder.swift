import Foundation

/// Лекции используют короткие окна и отметки времени, чтобы текст был доступен по ходу записи.
@MainActor
public final class LectureRecorder: ObservableObject {

    /// Допустимые окна лекции. Меньше трёх секунд модель теряет контекст и
    /// начинает угадывать; больше двадцати — текст появляется так редко, что
    /// смысл живой расшифровки пропадает.
    public static let windowRange: ClosedRange<Double> = 3...20
    public static let defaultWindowSeconds: Double = 6
    public static let overlapSeconds: Double = 1
    private static let sampleRate = 16_000

    public static func clampWindow(_ seconds: Double) -> Double {
        min(max(seconds, windowRange.lowerBound), windowRange.upperBound)
    }

    private let windowSeconds: Double

    /// Абзацы на сейчас. Пополняются по мере того, как окна закрываются.
    @Published public private(set) var paragraphs: [LectureParagraph] = []
    /// Идёт ли прямо сейчас распознавание закрывшегося окна. Экран показывает
    /// этим, что последние секунды ещё не на экране — вместо того чтобы
    /// придумывать несуществующий «уточняемый» текст.
    @Published public private(set) var isCatchingUp = false
    @Published public private(set) var detectedLanguage: String?
    /// Текст, который движок ещё уточняет. Он перепишется следующим
    /// обновлением, поэтому в абзацы не попадает и показывается приглушённо.
    /// У нарезки на окна его не бывает: там текст либо есть, либо нет.
    @Published public private(set) var volatileText = ""

    @Published public private(set) var completionIssue: String?
    public var isStreaming: Bool { liveEngine != nil }
    private var volatileRange: (Double, Double)?
    private var sessionID = UUID()
    private var audioPump: Task<Void, Never>?
    private var streamCursor = 0
    private var planner: DictationWindowPlanner
    private var segments: [TranscribedSegment] = []
    private var languageCounts: [String: Int] = [:]
    private var pump: Task<Void, Never>?
    private var liveEngine: (any LiveTranscribing)?
    private var silenceSamples = 0
    private var hasUnsettledSpeech = false
    private var pauseSeconds: Double = LectureParagraphBuilder.defaultPauseSeconds
    private let pollInterval: Duration

    public init(
        windowSeconds: Double = LectureRecorder.defaultWindowSeconds,
        pollInterval: Duration = .milliseconds(500)
    ) {
        self.windowSeconds = Self.clampWindow(windowSeconds)
        self.pollInterval = pollInterval
        self.planner = Self.makePlanner(windowSeconds: Self.clampWindow(windowSeconds))
    }

    private static func makePlanner(windowSeconds: Double) -> DictationWindowPlanner {
        DictationWindowPlanner(
            windowSamples: Int(windowSeconds * Double(sampleRate)),
            overlapSamples: Int(overlapSeconds * Double(sampleRate))
        )
    }

    /// Начинает считать окна по ходу записи.
    public func begin(
        transcriber: any Transcribing,
        language: TranscriptionLanguage,
        pauseSeconds: Double,
        availableSamples: @escaping @MainActor () -> Int,
        readSamples: @escaping @MainActor (Range<Int>) -> [Float]
    ) {
        cancel()
        self.pauseSeconds = pauseSeconds
        let interval = pollInterval
        pump = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.drainClosedWindows(
                    transcriber: transcriber,
                    language: language,
                    availableSamples: availableSamples,
                    readSamples: readSamples
                )
            }
        }
    }

    /// Досчитывает хвост и отдаёт окончательные абзацы.
    public func finish(
        transcriber: any Transcribing,
        language: TranscriptionLanguage,
        totalSamples: [Float]
    ) async -> [LectureParagraph] {
        await finish(transcriber: transcriber, language: language, totalSampleCount: totalSamples.count,
                     readSamples: { Array(totalSamples[$0]) })
    }

    public func finish(
        transcriber: any Transcribing,
        language: TranscriptionLanguage,
        totalSampleCount: Int,
        readSamples: @MainActor (Range<Int>) -> [Float]
    ) async -> [LectureParagraph] {
        let active = pump
        active?.cancel()
        await active?.value
        pump = nil
        isCatchingUp = true
        defer { isCatchingUp = false }
        while let window = planner.closedWindow(availableSamples: totalSampleCount) {
            await transcribe(readSamples(window), startingAt: window.lowerBound,
                             transcriber: transcriber, language: language)
            planner.commit(window)
        }
        if let tail = planner.tail(totalSamples: totalSampleCount) {
            await transcribe(readSamples(tail), startingAt: tail.lowerBound,
                             transcriber: transcriber, language: language)
            planner.commit(tail)
        }
        return paragraphs
    }

    /// Отменённая лекция не оставляет следов.
    public func cancel() {
        sessionID = UUID()
        audioPump?.cancel()
        audioPump = nil
        completionIssue = nil
        volatileRange = nil
        liveEngine?.cancel()
        liveEngine = nil
        pump?.cancel()
        pump = nil
        volatileText = ""
        planner = Self.makePlanner(windowSeconds: windowSeconds)
        segments = []
        languageCounts = [:]
        paragraphs = []
        detectedLanguage = nil
        isCatchingUp = false
    }

    // MARK: - Потоковый движок

    /// Ведёт лекцию потоковым распознавателем: звук подаётся по ходу, текст
    /// приходит обновлениями. Нарезка на окна здесь не участвует вовсе.
    public func beginStreaming(
        engine: any LiveTranscribing,
        language: TranscriptionLanguage,
        pauseSeconds: Double
    ) async throws {
        cancel()
        self.pauseSeconds = pauseSeconds
        let session = sessionID
        try await engine.prepare(language: language)
        guard session == sessionID, !Task.isCancelled else { engine.cancel(); throw CancellationError() }
        liveEngine = engine
        pump = Task { [weak self] in
            for await update in engine.updates {
                guard let self, session == self.sessionID, !Task.isCancelled else { return }
                self.absorb(update)
            }
        }
        silenceSamples = 0
        hasUnsettledSpeech = false
    }

    public func streamCapturedAudio(
        availableSamples: @escaping @MainActor () -> Int,
        readSamples: @escaping @MainActor (Range<Int>) -> [Float]
    ) {
        streamCursor = 0
        audioPump = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.forwardAvailableAudio(availableSamples: availableSamples(), readSamples: readSamples)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func forwardAvailableAudio(availableSamples: Int, readSamples: @MainActor (Range<Int>) -> [Float]) {
        let end = min(availableSamples, streamCursor + Self.sampleRate)
        guard end > streamCursor else { return }
        let samples = readSamples(streamCursor..<end)
        guard samples.count == end - streamCursor else { markIncomplete("Lecture audio could not be read"); return }
        appendStreamingAudio(samples)
        streamCursor = end
    }

    public func drainStreamingAudio(totalSamples: Int, readSamples: @MainActor (Range<Int>) -> [Float]) async {
        audioPump?.cancel()
        await audioPump?.value
        audioPump = nil
        while streamCursor < totalSamples {
            let previous = streamCursor
            forwardAvailableAudio(availableSamples: totalSamples, readSamples: readSamples)
            if streamCursor == previous { break }
            await Task.yield()
        }
    }

    public func markIncomplete(_ reason: String) {
        if completionIssue == nil { completionIssue = reason }
    }

    /// Порог тишины и её длительность, после которой текст закрепляется.
    ///
    /// Закреплять надо **в тишине, а не по часам**. Первая версия закрепляла
    /// раз в шесть секунд и резала слова посередине: `描述` («описание»)
    /// превратилось в `描。 魔术` — остаток распознан как «магия». Это та же
    /// беда стыков, от которой уходили, отказавшись от нарезки на окна.
    ///
    /// Порог громкости и длительность паузы — те же, что уже приняты в
    /// продукте: 0,004 RMS отделяет тихую речь от шума микрофона, 0,6 с —
    /// длительность, после которой фильтр хвоста считает тишину настоящей.
    static let silenceRMS: Float = 0.004
    static let settlePauseSeconds: Double = 0.6

    /// Отдаёт потоковому движку очередной кусок звука и закрепляет текст,
    /// когда говорящий замолчал.
    public func appendStreamingAudio(_ samples: [Float]) {
        liveEngine?.append(samples: samples)
        if let issue = liveEngine?.failureDescription { markIncomplete(issue) }
        guard !samples.isEmpty else { return }

        let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
        if rms >= Self.silenceRMS {
            silenceSamples = 0
            hasUnsettledSpeech = true
            return
        }
        silenceSamples += samples.count
        let pause = Double(silenceSamples) / Double(Self.sampleRate)
        // Закрепляем один раз на паузу и только если было что закреплять:
        // иначе долгое молчание дёргало бы движок впустую.
        guard hasUnsettledSpeech, pause >= Self.settlePauseSeconds else { return }
        hasUnsettledSpeech = false
        Task { [weak self] in await self?.liveEngine?.settle() }
    }

    /// Закрывает поток и отдаёт окончательные абзацы.
    public func finishStreaming() async -> [LectureParagraph] {
        isCatchingUp = true
        defer { isCatchingUp = false }
        await liveEngine?.finish()
        if let issue = liveEngine?.failureDescription { markIncomplete(issue) }
        liveEngine = nil
        // Дождаться, пока приём разберёт последние обновления, а не обрывать
        // его: устоявшийся хвост приходит ровно в момент завершения.
        await pump?.value
        pump = nil
        if !volatileText.isEmpty {
            markIncomplete("Speech did not finalize the last words")
            let range = volatileRange ?? (segments.last?.endSeconds ?? 0, segments.last?.endSeconds ?? 0)
            segments.append(TranscribedSegment(text: volatileText, startSeconds: range.0, endSeconds: range.1))
            paragraphs = LectureParagraphBuilder.build(from: segments, pauseSeconds: pauseSeconds)
        }
        volatileText = ""
        return paragraphs
    }

    private func absorb(_ update: LiveTranscriptUpdate) {
        guard let settled = update.settledSegment else {
            volatileRange = (update.startSeconds, update.endSeconds)
            volatileText = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }
        volatileText = ""
        segments.append(settled)
        paragraphs = LectureParagraphBuilder.build(from: segments, pauseSeconds: pauseSeconds)
    }

    // MARK: - Механика

    private func drainClosedWindows(
        transcriber: any Transcribing,
        language: TranscriptionLanguage,
        availableSamples: @MainActor () -> Int,
        readSamples: @MainActor (Range<Int>) -> [Float]
    ) async {
        while let window = planner.closedWindow(availableSamples: availableSamples()) {
            let samples = readSamples(window)
            // Неполное чтение окно не фиксирует: пропущенное окно — дыра в
            // записи. Вернёмся к нему на следующем опросе.
            guard samples.count == window.count else { return }
            let session = sessionID
            isCatchingUp = true
            await transcribe(
                samples,
                startingAt: window.lowerBound,
                transcriber: transcriber,
                language: language
            )
            // До фиксации, а не после: распознавание не прерывается на
            // полуслове, и пока оно шло, остановка или отмена могли
            // переустановить нарезку. Фиксация окна от прежней нарезки
            // нарушает условие `commit` и роняет процесс.
            guard session == sessionID else { return }
            planner.commit(window)
            if Task.isCancelled {
                isCatchingUp = false
                return
            }
            isCatchingUp = false
        }
    }

    /// Распознаёт отрезок и добавляет его сегменты, сдвинув их время на начало
    /// отрезка: модель отсчитывает время от начала того, что ей дали, а лекции
    /// нужно время от начала записи.
    ///
    /// Отказ окна лекцию не роняет: запись идёт, человек слушает. Окно
    /// пропускается, остальное остаётся на экране, причина уходит в журнал.
    /// Потерять минуту лекции хуже, чем показать её с пробелом.
    private func transcribe(
        _ samples: [Float],
        startingAt startSample: Int,
        transcriber: any Transcribing,
        language: TranscriptionLanguage
    ) async {
        guard !samples.isEmpty else { markIncomplete("Lecture audio window is unavailable"); return }
        guard samples.allSatisfy(\.isFinite) else { markIncomplete("Lecture audio contains invalid samples"); return }
        guard samples.contains(where: { $0.isFinite && abs($0) > 0.000_000_1 }) else { return }
        let session = sessionID
        let offset = Double(startSample) / Double(Self.sampleRate)
        do {
            // Подсказка языка здесь намеренно не передаётся, в отличие от
            // диктовки. Диктовка коротка и одноязычна, лекция — нет: в ней
            // переходят с китайского на английский и обратно, и привязка к
            // языку первого окна заставила бы читать чужую речь чужим языком.
            // Каждое окно определяет язык само.
            let result = try await transcriber.transcribe(
                TranscriptionRequest(samples: samples, language: language)
            )
            guard session == sessionID else { return }
            // Язык лекции в целом — тот, что встретился в большинстве окон.
            // Он идёт в карточку записи, а не в декодирование: на смешанной
            // лекции первое окно о языке всей лекции ничего не говорит.
            if let language = result.detectedLanguage, !language.isEmpty {
                languageCounts[language, default: 0] += 1
                detectedLanguage = languageCounts.max { $0.value < $1.value }?.key
            }
            // Перекрытие окон даёт повторы на стыке. Отбрасывается только
            // сегмент, целиком лежащий в уже принятом времени.
            //
            // Раньше условием было `startSeconds >= lastEnd`, и это теряло
            // речь: модель нередко склеивает перекрывшийся хвост с новыми
            // словами в один сегмент, который начинается до границы, а
            // кончается после. Такой сегмент выбрасывался целиком — вместе с
            // новыми словами. Размен сделан в сторону повтора: увидеть слово
            // дважды неприятно, не увидеть вовсе — потеря.
            let lastEnd = segments.last?.endSeconds ?? -.infinity
            let fresh = result.segments
                .map { $0.offset(by: offset) }
                .filter { $0.endSeconds > lastEnd }
            segments.append(contentsOf: fresh)
            paragraphs = LectureParagraphBuilder.build(from: segments, pauseSeconds: pauseSeconds)
        } catch {
            guard session == sessionID else { return }
            markIncomplete("A lecture audio window could not be transcribed")
            await DiagnosticLog.shared.log(
                "lecture.windowFailed",
                detail: String(describing: error)
            )
        }
    }
}
