import Foundation

/// Считает закрывшиеся окна записи, пока запись ещё идёт, чтобы после
/// остановки остался только хвост.
///
/// Границы отрезков считает `DictationWindowPlanner`, повтор на стыке снимает
/// `TranscriptChunkMerger` — тот же, которым склеивает окна тракт импорта.
/// Здесь только порядок: когда спрашивать звук, когда звать модель и что
/// делать с отменой.
///
/// Работа строго последовательна: следующее окно не запрашивается, пока не
/// досчитано предыдущее. Замер (`docs/status.md`) показал, что окно в 28 с
/// считается около 2,2 с — то есть очередь не копится с огромным запасом, а
/// две одновременные загрузки модели только отняли бы память у записи.
@MainActor
final class StreamingDictationTranscriber {

    /// Как часто спрашивать, не закрылось ли окно. Окно длиной в десятки
    /// секунд, так что секунда опроса ничего не стоит и не мажет границу
    /// заметно.
    private static let pollInterval = Duration.seconds(1)

    private let windowSamples: Int
    private let overlapSamples: Int

    private var planner: DictationWindowPlanner
    private var mergedText = ""
    private var detectedLanguage: String?
    private var pump: Task<Void, Never>?
    /// Отказ окна не роняет диктовку на месте: запись идёт, пользователь
    /// говорит. Он запоминается и решается при завершении.
    private var failure: Error?

    init(windowSamples: Int, overlapSamples: Int) {
        self.windowSamples = windowSamples
        self.overlapSamples = overlapSamples
        self.planner = DictationWindowPlanner(
            windowSamples: windowSamples,
            overlapSamples: overlapSamples
        )
    }

    /// Начинает считать окна по ходу записи.
    ///
    /// - Parameters:
    ///   - transcriber: уже загруженная модель; грузить её во время записи
    ///     этот тип не станет.
    ///   - language: тот же режим языка, что у обычной диктовки.
    ///   - availableSamples: сколько звука накоплено на сейчас.
    ///   - readSamples: копия отрезка, не опустошающая буфер записи.
    func begin(
        transcriber: any Transcribing,
        language: TranscriptionLanguage,
        availableSamples: @escaping @MainActor () -> Int,
        readSamples: @escaping @MainActor (Range<Int>) -> [Float]
    ) {
        cancel()
        pump = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
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

    /// Досчитывает хвост и отдаёт склеенный результат.
    ///
    /// `totalSamples` — вся запись целиком: из неё берётся только незакрытый
    /// хвост, но длина нужна, чтобы понять, где он кончается.
    func finish(
        transcriber: any Transcribing,
        language: TranscriptionLanguage,
        totalSamples: [Float]
    ) async throws -> TranscriptionResult {
        pump?.cancel()
        pump = nil

        if let failure {
            // Отказ окна не стоит целой диктовки: человек говорил, и запись
            // цела. Считанное выбрасывается, запись идёт в модель одним
            // проходом — медленнее, но без потери. Ошибка остаётся в журнале.
            await DiagnosticLog.shared.log(
                "dictation.windowFailed.fallback",
                detail: String(describing: failure)
            )
            reset()
            return try await transcriber.transcribe(
                TranscriptionRequest(samples: totalSamples, language: language)
            )
        }

        if let tail = planner.tail(totalSamples: totalSamples.count) {
            let result = try await transcriber.transcribe(
                TranscriptionRequest(samples: Array(totalSamples[tail]), language: language)
            )
            planner.commit(tail)
            absorb(result)
        }
        return TranscriptionResult(rawText: mergedText, detectedLanguage: detectedLanguage)
    }

    /// Отменённая запись не оставляет следов: считанные окна выбрасываются
    /// вместе с незавершённой работой.
    func cancel() {
        pump?.cancel()
        pump = nil
        reset()
    }

    private func reset() {
        mergedText = ""
        detectedLanguage = nil
        failure = nil
        planner = DictationWindowPlanner(
            windowSamples: windowSamples,
            overlapSamples: overlapSamples
        )
    }

    // MARK: - Механика

    private func drainClosedWindows(
        transcriber: any Transcribing,
        language: TranscriptionLanguage,
        availableSamples: @MainActor () -> Int,
        readSamples: @MainActor (Range<Int>) -> [Float]
    ) async {
        guard failure == nil else { return }
        while let window = planner.closedWindow(availableSamples: availableSamples()) {
            let samples = readSamples(window)
            // Гонка с аудиопотоком могла отдать меньше запрошенного. Окно не
            // фиксируется — иначе оно окажется пропущенным, а пропущенное
            // окно это дыра в записи. Вернёмся к нему на следующем опросе.
            guard samples.count == window.count else { return }
            do {
                let result = try await transcriber.transcribe(
                    TranscriptionRequest(samples: samples, language: language)
                )
                planner.commit(window)
                absorb(result)
            } catch {
                failure = error
                return
            }
            if Task.isCancelled { return }
        }
    }

    /// Язык берётся из первого окна и держится: авто-определение на каждом
    /// окне порознь дало бы разный язык внутри одной записи. Так же устроен
    /// накопитель тракта импорта.
    private func absorb(_ result: TranscriptionResult) {
        mergedText = TranscriptChunkMerger.merge(mergedText, with: result.rawText)
        if detectedLanguage == nil { detectedLanguage = result.detectedLanguage }
    }
}
