import Foundation

nonisolated public struct SpeechActivity: Equatable, Sendable {
    public let hasSpeech: Bool
    public let speechSeconds: Double
    public let firstSpeechStartSeconds: Double?
    public let lastSpeechEndSeconds: Double?

    static let none = SpeechActivity(
        hasSpeech: false, speechSeconds: 0, firstSpeechStartSeconds: nil, lastSpeechEndSeconds: nil
    )
}

/// Есть ли в записи речь: без неё Whisper выдумывает текст, и модель звать незачем.
nonisolated public enum SpeechGate {
    private static let frameSeconds = 0.02
    private static let absoluteFloor: Float = 0.004
    // WHY: множитель и потолок фона подобраны по записи речи 132 с и синтетическому
    // шуму (docs/status.md, «Детектор речи»); без потолка сплошная речь уносит порог выше себя.
    private static let noiseMultiplier: Float = 2.0
    private static let noiseCeiling: Float = 0.01
    private static let noisePercentile = 20
    private static let minimumRunFrames = 5
    private static let bridgeFrames = 15
    private static let minimumSpeechSeconds = 0.15

    public static func analyze(_ samples: [Float], sampleRate: Double = 16_000) -> SpeechActivity {
        let frameSize = max(1, Int(sampleRate * frameSeconds))
        let levels = frameLevels(samples, frameSize: frameSize)
        guard !levels.isEmpty else { return .none }

        let runs = speechRuns(levels: levels, threshold: threshold(for: levels))
        guard let first = runs.first, let last = runs.last else { return .none }
        let seconds = Double(runs.reduce(0) { $0 + $1.count }) * frameSeconds
        guard seconds >= minimumSpeechSeconds else { return .none }
        return SpeechActivity(
            hasSpeech: true,
            speechSeconds: seconds,
            firstSpeechStartSeconds: Double(first.lowerBound) * frameSeconds,
            lastSpeechEndSeconds: Double(last.upperBound + 1) * frameSeconds
        )
    }

    @concurrent
    public static func analyzeOffMain(_ samples: [Float], sampleRate: Double = 16_000) async -> SpeechActivity {
        analyze(samples, sampleRate: sampleRate)
    }

    private static func frameLevels(_ samples: [Float], frameSize: Int) -> [Float] {
        (0..<(samples.count / frameSize)).map { frame in
            var energy: Float = 0
            for index in (frame * frameSize)..<((frame + 1) * frameSize) {
                energy += samples[index] * samples[index]
            }
            return (energy / Float(frameSize)).squareRoot()
        }
    }

    private static func threshold(for levels: [Float]) -> Float {
        let sorted = levels.sorted()
        let quantile = sorted[min(sorted.count - 1, sorted.count * noisePercentile / 100)]
        return max(absoluteFloor, noiseMultiplier * min(quantile, noiseCeiling))
    }

    private static func speechRuns(levels: [Float], threshold: Float) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        var start: Int?
        for (frame, level) in levels.enumerated() {
            if level >= threshold {
                if start == nil { start = frame }
            } else if let begin = start {
                runs.append(begin...(frame - 1))
                start = nil
            }
        }
        if let begin = start { runs.append(begin...(levels.count - 1)) }

        var merged: [ClosedRange<Int>] = []
        for run in runs {
            if let last = merged.last, run.lowerBound - last.upperBound - 1 <= bridgeFrames {
                merged[merged.count - 1] = last.lowerBound...run.upperBound
            } else {
                merged.append(run)
            }
        }
        return merged.filter { $0.count >= minimumRunFrames }
    }
}
