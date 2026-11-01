import AVFoundation
import Foundation
import Speech

/// Потоковый распознаватель системы (`SpeechAnalyzer`, macOS 26).
///
/// Принимает звук по ходу записи и отдаёт два вида обновлений: устоявшиеся,
/// которые больше не изменятся, и уточняемые, которые следующий кусок
/// перепишет. Нарезки на окна здесь нет вовсе, а значит нет и стыков, на
/// которых терялись или повторялись слова.
///
/// Два модуля вместо одного: `SpeechTranscriber` — новая модель, знает 30
/// языков и на китайском обходит Whisper; `DictationTranscriber` — прежняя
/// клавиатурная диктовка, знает 54 языка, включая русский, но на нём заметно
/// слабее. Выбирается тот, который знает нужный язык, с предпочтением первого.
/// Доступен с macOS 26: до неё `SpeechAnalyzer` не существует. Приложение
/// собирается под macOS 15, поэтому тип ограничен по доступности, а выбор
/// движка на более старой системе молча остаётся за Whisper.
@available(macOS 26.0, *)
@MainActor
public final class SystemLiveTranscriber: LiveTranscribing {

    public private(set) var failureDescription: String?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var collector: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    /// Сколько звука подано. По нему считается точка закрепления.
    private var fedSamples = 0

    private let updateStream: AsyncStream<LiveTranscriptUpdate>
    private let updateContinuation: AsyncStream<LiveTranscriptUpdate>.Continuation

    public var updates: AsyncStream<LiveTranscriptUpdate> { updateStream }

    public init() {
        (updateStream, updateContinuation) = AsyncStream<LiveTranscriptUpdate>.makeStream(bufferingPolicy: .bufferingOldest(256))
    }

    private enum ModuleKind { case speech, dictation }

    private static func localeIdentifier(for language: TranscriptionLanguage) -> String? {
        switch language {
        case .zh: return "zh-CN"
        case .ru: return "ru-RU"
        case .en: return "en-US"
        // Автоопределения у системного распознавателя нет: язык задаётся до
        // начала. Выбор языка на экране лекции существует ровно поэтому.
        case .auto: return nil
        }
    }

    private static func matches(_ locales: [Locale], _ identifier: String) -> Bool {
        let wanted = identifier.replacingOccurrences(of: "-", with: "_")
        return locales.contains { $0.identifier.replacingOccurrences(of: "-", with: "_") == wanted }
    }

    private static func pickModuleKind(_ identifier: String) async -> ModuleKind? {
        if matches(await SpeechTranscriber.supportedLocales, identifier) { return .speech }
        if matches(await DictationTranscriber.supportedLocales, identifier) { return .dictation }
        return nil
    }

    public func prepare(language: TranscriptionLanguage) async throws {
        guard let identifier = Self.localeIdentifier(for: language),
            let kind = await Self.pickModuleKind(identifier)
        else {
            throw LiveTranscribingError.unsupportedLanguage(String(describing: language))
        }
        let locale = Locale(identifier: identifier)

        let module: any SpeechModule
        let startCollector: () -> Task<Void, Never>
        switch kind {
        case .speech:
            let transcriber = SpeechTranscriber(
                locale: locale,
                preset: .timeIndexedProgressiveTranscription
            )
            module = transcriber
            startCollector = { [weak self] in Task { [weak self] in
                guard let self else { return }
                await Self.drain(transcriber.results, into: self.updateContinuation,
                    onFailure: { self.failureDescription = "Speech result stream failed" }) { result in
                    Self.update(text: String(result.text.characters), isFinal: result.isFinal, range: result.range)
                }
            } }
        case .dictation:
            let transcriber = DictationTranscriber(
                locale: locale,
                preset: .progressiveLongDictation
            )
            module = transcriber
            startCollector = { [weak self] in Task { [weak self] in
                guard let self else { return }
                await Self.drain(transcriber.results, into: self.updateContinuation,
                    onFailure: { self.failureDescription = "Speech result stream failed" }) { result in
                    Self.update(text: String(result.text.characters), isFinal: result.isFinal, range: result.range)
                }
            } }
        }

        guard await AssetInventory.status(forModules: [module]) == .installed else {
            throw LiveTranscribingError.assetsNotInstalled(identifier)
        }

        let analyzer = SpeechAnalyzer(modules: [module])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        try await analyzer.prepareToAnalyze(in: format)

        let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(128))
        try await analyzer.start(inputSequence: input)

        self.analyzer = analyzer
        self.inputContinuation = continuation
        self.inputFormat = format
        self.converter = Self.makeConverter(to: format)

        collector = startCollector()
    }

    public func append(samples: [Float]) {
        guard let continuation = inputContinuation,
            let format = inputFormat,
            let buffer = Self.buffer(from: samples, to: format, using: converter)
        else {
            if !samples.isEmpty { failureDescription = "Speech audio conversion failed" }
            return
        }
        if case .dropped = continuation.yield(AnalyzerInput(buffer: buffer)) {
            failureDescription = "Speech input overloaded; transcription is incomplete"
        }
        fedSamples += samples.count
    }

    public func settle() async {
        guard let analyzer, fedSamples > 0 else { return }
        let through = CMTime(value: CMTimeValue(fedSamples), timescale: 16_000)
        do { try await analyzer.finalize(through: through) }
        catch { failureDescription = "Speech finalization failed" }
    }

    public func finish() async {
        inputContinuation?.finish()
        inputContinuation = nil
        do { try await analyzer?.finalizeAndFinishThroughEndOfInput() }
        catch {
            failureDescription = "Speech finalization failed"
            await analyzer?.cancelAndFinishNow()
            collector?.cancel()
        }
        // Дождаться, пока пересылка доставит последние результаты, а не
        // обрывать её. Прежде здесь стояла отмена сразу после команды
        // закончить — а весь устоявшийся текст приходит именно в этот момент,
        // одним куском. Он терялся: 13 секунд речи давали одно слово.
        await collector?.value
        collector = nil
        analyzer = nil
        updateContinuation.finish()
    }

    public func cancel() {
        inputContinuation?.finish()
        inputContinuation = nil
        collector?.cancel()
        collector = nil
        analyzer = nil
        updateContinuation.finish()
    }

    // MARK: - Звук

    /// Распознаватель просит 16 кГц моно — ровно то, что производит захват, —
    /// но целыми числами, а не с плавающей точкой.
    private static func makeConverter(to format: AVAudioFormat?) -> AVAudioConverter? {
        guard let format,
            let source = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: format.sampleRate,
                channels: format.channelCount,
                interleaved: false
            )
        else { return nil }
        if source.commonFormat == format.commonFormat { return nil }
        return AVAudioConverter(from: source, to: format)
    }

    private static func buffer(
        from samples: [Float],
        to format: AVAudioFormat,
        using converter: AVAudioConverter?
    ) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
            let source = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: format.sampleRate,
                channels: format.channelCount,
                interleaved: false
            ),
            let input = AVAudioPCMBuffer(
                pcmFormat: source,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        else { return nil }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            input.floatChannelData?[0].update(from: base, count: samples.count)
        }
        guard let converter else { return input }
        guard let output = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return nil }
        // Тот же приём, что в `AudioTapProcessor`: входной блок проверяется
        // на `Sendable`, хотя вызывается синхронно и ровно один раз.
        nonisolated(unsafe) var delivered = false
        nonisolated(unsafe) let handoff = input
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if delivered {
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return handoff
        }
        return error == nil ? output : nil
    }

    // MARK: - Результаты

    /// Закрывает поток при любом исходе: потерянная ошибка прежде оставляла лекцию ждать вечно.
    static func drain<Results: AsyncSequence>(
        _ results: Results,
        into continuation: AsyncStream<LiveTranscriptUpdate>.Continuation,
        onFailure: () -> Void = {},
        map: (Results.Element) -> LiveTranscriptUpdate
    ) async {
        do {
            for try await result in results {
                if case .dropped = continuation.yield(map(result)) { onFailure() }
            }
        } catch {
            onFailure()
            await DiagnosticLog.shared.log("lecture.liveResults.failed", detail: ErrorSummary.describe(error))
        }
        continuation.finish()
    }

    private static func update(text: String, isFinal: Bool, range: CMTimeRange) -> LiveTranscriptUpdate {
        LiveTranscriptUpdate(
            text: text,
            isFinal: isFinal,
            startSeconds: range.start.seconds.isFinite ? range.start.seconds : 0,
            endSeconds: range.end.seconds.isFinite ? range.end.seconds : 0
        )
    }
}
