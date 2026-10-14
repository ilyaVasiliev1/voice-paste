import Foundation
import Testing

@testable import VoicePaste

/// Детектор речи перед моделью. Сигналы синтетические и повторяемые: на живых
/// записях пороги не подбирались (подбор — в бейкоффе блока M3).
@Suite("Детектор речи")
struct SpeechGateTests {

    static let rate = 16_000

    /// Повторяемый «шум»: линейный конгруэнтный генератор, амплитуда ±level.
    static func noise(seconds: Double, level: Float) -> [Float] {
        var state: UInt32 = 12_345
        return (0..<Int(seconds * Double(rate))).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return (Float(state >> 8) / Float(1 << 24) * 2 - 1) * level
        }
    }

    static func tone(seconds: Double, amplitude: Float) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { amplitude * sin(Float($0) * 0.3) }
    }

    static func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(rate)))
    }

    @Test("тишина — речи нет")
    func silenceHasNoSpeech() {
        let activity = SpeechGate.analyze(Self.silence(seconds: 3))
        #expect(!activity.hasSpeech)
        #expect(activity.lastSpeechEndSeconds == nil)
    }

    @Test("ровный шум выше порога громкости — речи нет")
    func steadyNoiseHasNoSpeech() {
        // Громкость выше 0.004 пропускает прежняя проверка по всей записи;
        // детектор обязан отличить шум от речи по отношению к фону.
        let activity = SpeechGate.analyze(Self.noise(seconds: 3, level: 0.03))
        #expect(!activity.hasSpeech)
    }

    @Test("слово среди тишины — речь найдена, конец назван")
    func burstInSilenceIsSpeech() throws {
        let samples = Self.silence(seconds: 1) + Self.tone(seconds: 0.6, amplitude: 0.1) + Self.silence(seconds: 1.5)
        let activity = SpeechGate.analyze(samples)

        #expect(activity.hasSpeech)
        let end = try #require(activity.lastSpeechEndSeconds)
        #expect(abs(end - 1.6) < 0.1)
    }

    @Test("сплошная речь без пауз — речь найдена")
    func continuousSpeechIsSpeech() throws {
        let activity = SpeechGate.analyze(Self.tone(seconds: 4, amplitude: 0.08))
        #expect(activity.hasSpeech)
        let end = try #require(activity.lastSpeechEndSeconds)
        #expect(abs(end - 4.0) < 0.1)
    }

    @Test("тихая речь над тихим фоном — речь найдена")
    func quietSpeechOverQuietFloorIsSpeech() {
        let floor = Self.noise(seconds: 2, level: 0.0006)
        let speech = Self.tone(seconds: 0.8, amplitude: 0.01)
        let activity = SpeechGate.analyze(floor + speech + floor)
        #expect(activity.hasSpeech)
    }

    @Test("щелчок в десять миллисекунд — не речь")
    func clickIsNotSpeech() {
        var samples = Self.silence(seconds: 2)
        for index in 8_000..<(8_000 + 160) { samples[index] = 0.5 }
        #expect(!SpeechGate.analyze(samples).hasSpeech)
    }

    @Test("пустой буфер — речи нет, без падения")
    func emptyBuffer() {
        #expect(!SpeechGate.analyze([]).hasSpeech)
    }

    @Test("анализ вне главного актора возвращает тот же результат")
    func offMainAnalysisMatches() async {
        let samples = Self.silence(seconds: 1) + Self.tone(seconds: 0.5, amplitude: 0.1)
        let direct = SpeechGate.analyze(samples)
        let viaConcurrent = await SpeechGate.analyzeOffMain(samples)
        #expect(direct == viaConcurrent)
    }
}
