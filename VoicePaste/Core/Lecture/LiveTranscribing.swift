import Foundation

/// Движок распознавания лекции.
///
/// Выбор не вкусовой. Замер 2026-09-21 на одной и той же синтезированной речи
/// (`docs/status.md`): на китайском система считает 29 секунд за 0,50 с с 2,4 %
/// ошибок против 2,26 с и 4,9 % у Whisper; на русском — 0,73 с при 14 % ошибок
/// против 1,84 с при нуле и полной пунктуации. Каждый движок выигрывает на
/// своём языке, поэтому выбор остаётся за владельцем.
nonisolated public enum LectureEngine: String, Codable, CaseIterable, Sendable {
    /// Потоковый распознаватель системы: текст идёт по ходу речи.
    case system
    /// Whisper с нарезкой на окна: текст появляется порциями.
    case whisper

    /// Доступен ли потоковый распознаватель на этой системе. До macOS 26 его
    /// не существует, и выбор сводится к одному Whisper.
    public static var isSystemEngineAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// Движок, разумный для языка, когда владелец не выбрал сам.
    public static func `default`(for language: TranscriptionLanguage) -> LectureEngine {
        guard isSystemEngineAvailable else { return .whisper }
        return preferredIgnoringAvailability(for: language)
    }

    static func preferredIgnoringAvailability(for language: TranscriptionLanguage) -> LectureEngine {
        switch language {
        case .zh: return .system
        // Русского нет у потокового распознавателя системы вовсе, а у его
        // соседа для диктовки он есть, но ошибается вчетверо чаще Whisper.
        case .ru: return .whisper
        case .en: return .system
        // При автоопределении язык заранее неизвестен, а Whisper знает их все.
        case .auto: return .whisper
        }
    }
}

/// Кусок расшифровки, пришедший от потокового движка.
nonisolated public struct LiveTranscriptUpdate: Sendable, Equatable {
    public let text: String
    /// Устоявшийся текст уже не изменится; уточняемый будет переписан
    /// следующим обновлением и показывается приглушённо.
    public let isFinal: Bool
    public let startSeconds: Double
    public let endSeconds: Double

    public init(text: String, isFinal: Bool, startSeconds: Double, endSeconds: Double) {
        self.text = text
        self.isFinal = isFinal
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }

    /// Устоявшийся кусок как сегмент — в том же виде, в каком его понимает
    /// сборщик абзацев. Уточняемый в абзацы не попадает: он ещё изменится.
    public var settledSegment: TranscribedSegment? {
        guard isFinal else { return nil }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        return TranscribedSegment(text: clean, startSeconds: startSeconds, endSeconds: endSeconds)
    }
}

/// Распознаватель, который принимает звук по ходу записи и отдаёт обновления,
/// не дожидаясь её конца.
///
/// Отличается от `Transcribing` не деталью, а устройством: тот берёт готовый
/// отрезок и возвращает текст, этому звук подают потоком. Нарезка на окна
/// была попыткой изобразить второе через первое, и её цена — рывки текста и
/// потери на стыках.
@MainActor
public protocol LiveTranscribing: AnyObject {
    /// Готовит движок к работе: язык, при необходимости — доустановка
    /// языковых данных. Вызывается до первого звука.
    func prepare(language: TranscriptionLanguage) async throws

    /// Принимает очередной кусок звука: 16 кГц, моно, Float32.
    func append(samples: [Float])

    /// Обновления по мере распознавания.
    var updates: AsyncStream<LiveTranscriptUpdate> { get }

    /// Просит движок закрепить всё, что распознано к этому моменту.
    ///
    /// Системный распознаватель сам закрепляет текст редко — на длинной паузе
    /// или в конце. На непрерывной лекции это значит, что абзацев не будет до
    /// остановки, а вся лекция станет одним куском. Лекция зовёт это
    /// периодически, чтобы текст оседал абзацами по ходу.
    func settle() async

    /// Досчитывает остаток и закрывает поток.
    func finish() async

    /// Прекращает работу, ничего не досчитывая.
    func cancel()
}

nonisolated public enum LiveTranscribingError: Error, Equatable, Sendable {
    /// Язык не поддерживается этим движком.
    case unsupportedLanguage(String)
}
