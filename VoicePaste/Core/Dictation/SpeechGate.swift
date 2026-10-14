import Foundation

/// Где в записи есть речь.
nonisolated public struct SpeechActivity: Equatable, Sendable {
    public let hasSpeech: Bool
    public let speechSeconds: Double
    public let firstSpeechStartSeconds: Double?
    public let lastSpeechEndSeconds: Double?

    static let none = SpeechActivity(
        hasSpeech: false, speechSeconds: 0, firstSpeechStartSeconds: nil, lastSpeechEndSeconds: nil
    )
}

/// Решает, есть ли в записи речь, ещё до модели: на записи без речи Whisper
/// выдумывает текст («Thank you»), и единственный надёжный ответ — не звать его.
///
/// Громкость кадра сравнивается с оценкой фона самой записи, а не только с
/// абсолютным порогом: ровный шум громче 0.004 проходит проверку по всей
/// записи, но речью не является. Пороги подобраны по записи речи 132 с и
/// синтетическому шуму (`docs/status.md`, «Детектор речи»); подбор на других
/// микрофонах — в бейкоффе блока M3.
nonisolated public enum SpeechGate {
    private static let frameSeconds = 0.02
    /// Тот же порог, что у проверки записи целиком (`spec/dictation`).
    private static let absoluteFloor: Float = 0.004
    private static let noiseMultiplier: Float = 2.0
    /// Фон не оценивается выше этого: в записи сплошной речи нижняя квантиль
    /// и есть речь, и без потолка порог ушёл бы выше самой речи.
    private static let noiseCeiling: Float = 0.01
    private static let noisePercentile = 20
    private static let minimumRunFrames = 5
    private static let bridgeFrames = 15
    private static let minimumSpeechSeconds = 0.15

    public static func analyze(_ samples: [Float], sampleRate: Double = 16_000) -> SpeechActivity {
        let frameSize = max(1, Int(sampleRate * frameSeconds))
        let frameCount = samples.count / frameSize
        guard frameCount > 0 else { return .none }

        var levels = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            var energy: Float = 0
            for index in (frame * frameSize)..<((frame + 1) * frameSize) {
                energy += samples[index] * samples[index]
            }
            levels[frame] = (energy / Float(frameSize)).squareRoot()
        }

        let sorted = levels.sorted()
        let quantile = sorted[min(sorted.count - 1, sorted.count * noisePercentile / 100)]
        let threshold = max(absoluteFloor, noiseMultiplier * min(quantile, noiseCeiling))

        var runs: [ClosedRange<Int>] = []
        var start: Int?
        for frame in 0..<frameCount {
            if levels[frame] >= threshold {
                if start == nil { start = frame }
            } else if let begin = start {
                runs.append(begin...(frame - 1))
                start = nil
            }
        }
        if let begin = start { runs.append(begin...(frameCount - 1)) }

        var merged: [ClosedRange<Int>] = []
        for run in runs {
            if let last = merged.last, run.lowerBound - last.upperBound - 1 <= bridgeFrames {
                merged[merged.count - 1] = last.lowerBound...run.upperBound
            } else {
                merged.append(run)
            }
        }
        let kept = merged.filter { $0.count >= minimumRunFrames }
        guard let first = kept.first, let last = kept.last else { return .none }

        let speechSeconds = Double(kept.reduce(0) { $0 + $1.count }) * frameSeconds
        guard speechSeconds >= minimumSpeechSeconds else { return .none }
        return SpeechActivity(
            hasSpeech: true,
            speechSeconds: speechSeconds,
            firstSpeechStartSeconds: Double(first.lowerBound) * frameSeconds,
            lastSpeechEndSeconds: Double(last.upperBound + 1) * frameSeconds
        )
    }

    /// Тот же анализ вне главного актора: запись в минуты длиной не должна
    /// занимать интерфейс.
    @concurrent
    public static func analyzeOffMain(_ samples: [Float], sampleRate: Double = 16_000) async -> SpeechActivity {
        analyze(samples, sampleRate: sampleRate)
    }
}
