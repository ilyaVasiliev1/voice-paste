import Foundation

/// Распознавание как шаг конвейера; диктовка с окнами по ходу записи не умещается в `Transcribing`.
nonisolated public protocol Recognizing: Sendable {
    func recognize(samples: [Float], language: TranscriptionLanguage) async throws -> TranscriptionResult
}

/// Прямое распознавание одним вызовом движка — для импорта и тестов.
nonisolated public struct EngineRecognizer: Recognizing {
    private let engine: any Transcribing

    public init(engine: any Transcribing) {
        self.engine = engine
    }

    public func recognize(samples: [Float], language: TranscriptionLanguage) async throws -> TranscriptionResult {
        try await engine.transcribe(TranscriptionRequest(samples: samples, language: language))
    }
}

/// Результат конвейера до доставки: текст ещё нигде не вставлен и не сохранён.
nonisolated public struct Draft: Sendable, Equatable {
    public var rawText: String
    public var text: String
    public var detectedLanguage: String?
    public var durationMilliseconds: Int

    public init(rawText: String, text: String, detectedLanguage: String?, durationMilliseconds: Int) {
        self.rawText = rawText
        self.text = text
        self.detectedLanguage = detectedLanguage
        self.durationMilliseconds = durationMilliseconds
    }
}

/// Почему запись не дошла до модели.
nonisolated public enum PipelineRejection: Sendable, Equatable {
    case tooShort
    case belowNoiseFloor
    case noSpeech
}

nonisolated public enum PipelineOutcome: Sendable, Equatable {
    case draft(Draft)
    case rejected(PipelineRejection)
}

/// Вход конвейера: звук и всё, что нужно для приведения текста.
nonisolated public struct DictationInput: Sendable {
    public var samples: [Float]
    public var language: TranscriptionLanguage
    public var autoCorrectSafeTypos: Bool

    public init(samples: [Float], language: TranscriptionLanguage, autoCorrectSafeTypos: Bool) {
        self.samples = samples
        self.language = language
        self.autoCorrectSafeTypos = autoCorrectSafeTypos
    }
}

/// Шаги диктовки от звука до черновика; доставка и история — снаружи.
nonisolated public struct DictationPipeline: Sendable {

    // WHY: на меньшем звуке модель выдаёт правдоподобную выдумку вроде «Продолжение следует…».
    public static let minimumSamples = 8_000

    /// Громкость записи, ниже которой это шум микрофона, а не тихая речь.
    public static let minimumCaptureRMS: Float = 0.004

    private static let samplesPerMillisecond = 16

    private let normalizer: TextNormalizer

    public init(normalizer: TextNormalizer) {
        self.normalizer = normalizer
    }

    /// Идёт до показа «обработка»: отказ сразу сменяет окно ошибкой.
    public func admitCapture(sampleCount: Int, captureRMS: Float) -> PipelineRejection? {
        guard sampleCount >= Self.minimumSamples else { return .tooShort }
        guard captureRMS >= Self.minimumCaptureRMS else { return .belowNoiseFloor }
        return nil
    }

    /// `onSpeechConfirmed` — один раз после детектора речи и до распознавания.
    public func run(
        _ input: DictationInput,
        vocabulary: @Sendable () async -> [VocabularyEntry],
        recognizer: any Recognizing,
        onSpeechConfirmed: @Sendable () async -> Void
    ) async throws -> PipelineOutcome {
        let samples = input.samples
        guard await SpeechGate.analyzeOffMain(samples).hasSpeech else {
            return .rejected(.noSpeech)
        }
        await onSpeechConfirmed()

        let recognized = try await recognizer.recognize(samples: samples, language: input.language)
        let draft = await finish(
            recognized,
            language: input.language,
            vocabulary: await vocabulary(),
            autoCorrectSafeTypos: input.autoCorrectSafeTypos,
            durationMilliseconds: samples.count / Self.samplesPerMillisecond
        )
        // Движок, который сам не проверяет пустоту, не должен вставить пустую строку.
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscribingError.emptyAudio
        }
        return .draft(draft)
    }

    /// Приведение распознанного текста: общий последний шаг диктовки и импорта.
    public func finish(
        _ recognized: TranscriptionResult,
        language: TranscriptionLanguage,
        vocabulary: [VocabularyEntry],
        autoCorrectSafeTypos: Bool,
        durationMilliseconds: Int
    ) async -> Draft {
        let (text, _) = await normalizer.normalizeInBackground(
            rawText: recognized.rawText,
            language: language,
            vocabulary: vocabulary,
            autoCorrectSafeTypos: autoCorrectSafeTypos
        )
        return Draft(
            rawText: recognized.rawText,
            text: text,
            detectedLanguage: recognized.detectedLanguage,
            durationMilliseconds: durationMilliseconds
        )
    }
}
