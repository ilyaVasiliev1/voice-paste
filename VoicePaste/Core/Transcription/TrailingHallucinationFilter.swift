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

    /// A short natural pause at the end of a sentence must not alter text.
    /// A model-only segment is removed only after at least 0.6 s of detected
    /// silence and with its own timestamp at least 0.2 s after real speech.
    /// The exact Russian terminal filler is additionally reserved as a
    /// decoder artefact and removed even when timestamps are coalesced.
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

        if let terminal = segments.last,
           knownTerminalFillers.contains(canonical(terminal.text)),
           let lastAudibleSecond = lastAudibleSecond(
                in: samples,
                sampleRate: sampleRate
           ) {
            if terminal.startSeconds >= lastAudibleSecond + 0.2 {
                let suffix = terminal.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !suffix.isEmpty,
                   rawText.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(suffix) {
                    return String(rawText.dropLast(suffix.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        // Some decoders coalesce speech and filler into one segment. A long
        // silent tail plus an appended filler is sufficient evidence, but a
        // transcript consisting only of the phrase is preserved: that is the
        // explicit user-dictated case covered by AT-053.
        return canonical(rawText) == "продолжение следует"
            ? rawText
            : removingKnownTerminalFiller(rawText)
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
    private nonisolated static func lastAudibleSecond(
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
