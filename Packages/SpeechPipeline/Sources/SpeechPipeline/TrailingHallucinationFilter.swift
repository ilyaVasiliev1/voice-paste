import Foundation

/// Removes a known Whisper terminal filler only when the audio evidence also
/// contains a long silent tail. Text alone is never enough evidence: a user
/// may legitimately dictate the same phrase.
public enum TrailingHallucinationFilter {
    public struct Segment: Sendable, Equatable {
        public let text: String
        public let startSeconds: Double

        public nonisolated init(text: String, startSeconds: Double) {
            self.text = text
            self.startSeconds = startSeconds
        }
    }

    private nonisolated static let knownTerminalFillers: Set<String> = [
        "продолжение следует",
        "to be continued",
    ]

    /// Известная галлюцинация декодера на тишине: модель дописывает
    /// субтитровую концовку, которой в речи не было.
    ///
    /// Публично — потому что убирать её надо не только из готового текста, но
    /// и из сегментов: учебный режим читает именно их, и там она всплывала.
    public nonisolated static func isTerminalFiller(_ text: String) -> Bool {
        knownTerminalFillers.contains(canonical(text))
    }

    /// Сегмент, начавшийся позже последнего слышимого звука плюс этот запас, — не речь.
    public nonisolated static let afterSpeechMargin = 0.2

    /// После долгой тишины снимает любой хвост сегментов, начавшихся позже последнего слышимого звука.
    public nonisolated static func filtering(
        rawText: String,
        segments: [Segment],
        samples: [Float],
        hadLongTrailingSilence: Bool? = nil,
        sampleRate: Double = 16_000
    ) -> String {
        let hadLongTrailingSilence = hadLongTrailingSilence
            ?? self.hasLongTrailingSilence(in: samples, sampleRate: sampleRate)
        guard hadLongTrailingSilence else { return rawText }

        var text = rawText
        var remaining = segments
        if let lastAudible = lastAudibleSecond(in: samples, sampleRate: sampleRate) {
            while let terminal = remaining.last,
                  terminal.startSeconds >= lastAudible + afterSpeechMargin {
                // WHY: в тексте отдельного сегмента остаются метки времени, в готовом тексте их нет.
                let suffix = WhisperSpecialTokens.strip(terminal.text)
                let current = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !suffix.isEmpty, current.hasSuffix(suffix) else { break }
                text = String(current.dropLast(suffix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                remaining.removeLast()
            }
        }

        // WHY: склеенный сегмент по времени не разделить; фраза целиком сохраняется — её могли сказать (AT-053).
        return canonical(text) == "продолжение следует"
            ? text
            : removingKnownTerminalFiller(text)
    }

    /// Trims a long silent tail before it reaches Whisper. This addresses the
    /// cause of terminal hallucinations, rather than merely hiding one known
    /// phrase afterwards. A quarter-second pad preserves natural final
    /// consonants and brief pauses.
    public nonisolated static func trimmingLongTrailingSilence(
        from samples: [Float],
        sampleRate: Double = 16_000
    ) -> [Float] {
        guard let lastAudibleSecond = lastAudibleSecond(in: samples, sampleRate: sampleRate) else {
            return samples
        }
        let audioDuration = Double(samples.count) / sampleRate
        guard audioDuration - lastAudibleSecond >= 0.6 else { return samples }
        let retainedSampleCount = min(
            samples.count,
            Int((lastAudibleSecond + 0.25) * sampleRate)
        )
        return Array(samples.prefix(retainedSampleCount))
    }

    public nonisolated static func hasLongTrailingSilence(
        in samples: [Float],
        sampleRate: Double = 16_000
    ) -> Bool {
        guard let lastAudibleSecond = lastAudibleSecond(in: samples, sampleRate: sampleRate) else {
            return false
        }
        return Double(samples.count) / sampleRate - lastAudibleSecond >= 0.6
    }

    /// Finds the final 20 ms window with enough signal energy for speech.
    /// The loop runs on the transcription executor, never on the UI actor.
    public nonisolated static func lastAudibleSecond(
        in samples: [Float],
        sampleRate: Double
    ) -> Double? {
        guard sampleRate > 0 else { return nil }
        let windowSize = max(1, Int(sampleRate * 0.02))
        let minimumRMS: Float = 0.004

        var upperBound = samples.count
        while upperBound > 0 {
            let lowerBound = max(0, upperBound - windowSize)
            let window = samples[lowerBound..<upperBound]
            let energy = window.reduce(Float.zero) { $0 + $1 * $1 }
            let rms = sqrt(energy / Float(window.count))
            if rms >= minimumRMS {
                return Double(upperBound) / sampleRate
            }
            upperBound = lowerBound
        }
        return nil
    }

    private nonisolated static func canonical(_ text: String) -> String {
        text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
    }

    private nonisolated static func removingKnownTerminalFiller(_ rawText: String) -> String {
        let filler = "продолжение следует"
        guard let range = rawText.range(
            of: filler,
            options: [.caseInsensitive, .backwards]
        ), rawText[range.upperBound...].allSatisfy({
            $0.isWhitespace || $0.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
        }) else {
            return rawText
        }
        return String(rawText[..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
