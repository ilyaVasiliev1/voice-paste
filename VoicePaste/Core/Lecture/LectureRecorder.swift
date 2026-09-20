import Foundation

/// Ведёт запись лекции: считает закрывшиеся окна по ходу и пересобирает
/// абзацы, чтобы текст пополнялся на экране до остановки.
///
/// Отличие от диктовки — в размере окна и в том, что здесь нужны времена.
/// Диктовке важен один готовый текст как можно быстрее; лекции важно, чтобы
/// сказанное появлялось на экране, и чтобы к месту в записи можно было
/// вернуться.
///
/// Окно короче диктовочного намеренно. Замер (`docs/status.md`): накладная
/// около 0,51 с на вызов плюс 0,063 с на секунду речи, то есть окно в 10 с
/// считается около 1,1 с. Сказанное появляется примерно через секунду после
/// того, как окно закрылось. Длиннее — экономнее по процессору, но ровно за
/// счёт того, ради чего режим и сделан.
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

    private var planner: DictationWindowPlanner
    private var segments: [TranscribedSegment] = []
    private var pump: Task<Void, Never>?
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
        pump?.cancel()
        pump = nil
        isCatchingUp = true
        defer { isCatchingUp = false }

        if let tail = planner.tail(totalSamples: totalSamples.count) {
            await transcribe(
                Array(totalSamples[tail]),
                startingAt: tail.lowerBound,
                transcriber: transcriber,
                language: language
            )
            planner.commit(tail)
        }
        return paragraphs
    }

    /// Отменённая лекция не оставляет следов.
    public func cancel() {
        pump?.cancel()
        pump = nil
        planner = Self.makePlanner(windowSeconds: windowSeconds)
        segments = []
        paragraphs = []
        detectedLanguage = nil
        isCatchingUp = false
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
            if Task.isCancelled {
                isCatchingUp = false
                return
            }
            planner.commit(window)
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
        let offset = Double(startSample) / Double(Self.sampleRate)
        do {
            let result = try await transcriber.transcribe(
                TranscriptionRequest(
                    samples: samples,
                    language: language,
                    detectedLanguageHint: detectedLanguage
                )
            )
            if detectedLanguage == nil { detectedLanguage = result.detectedLanguage }
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
            await DiagnosticLog.shared.log(
                "lecture.windowFailed",
                detail: String(describing: error)
            )
        }
    }
}
