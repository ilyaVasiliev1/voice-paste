import Foundation
import Testing

@testable import VoicePaste

/// Концовка после речи снимается по звуку, а не по списку фраз: любой
/// сегмент, начавшийся после последнего слышимого звука, — не речь.
/// «Thank you» в списке известных фраз нет, и именно она кончала записи
/// владельца (история 14.10.2026).
@Suite("Фильтр концовки по звуку")
struct AudioEvidenceFilterTests {

    private static let rate = 16_000

    private static func speech(seconds: Double) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { 0.1 * sin(Float($0) * 0.3) }
    }

    private static func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(rate)))
    }

    private typealias Segment = TrailingHallucinationFilter.Segment

    @Test("«Thank you» после речи и тишины снимается, хотя её нет в списке")
    func unlistedPhraseAfterSpeechIsRemoved() {
        let samples = Self.speech(seconds: 2) + Self.silence(seconds: 1)
        let text = TrailingHallucinationFilter.filtering(
            rawText: "Привет, мир. Thank you.",
            segments: [Segment(text: "Привет, мир.", startSeconds: 0), Segment(text: " Thank you.", startSeconds: 2.3)],
            samples: samples
        )
        #expect(text == "Привет, мир.")
    }

    @Test("любая другая концовка после тишины тоже снимается")
    func anyTrailingTextAfterSilenceIsRemoved() {
        let samples = Self.speech(seconds: 2) + Self.silence(seconds: 1)
        let text = TrailingHallucinationFilter.filtering(
            rawText: "Привет, мир. Спасибо за просмотр.",
            segments: [Segment(text: "Привет, мир.", startSeconds: 0), Segment(text: " Спасибо за просмотр.", startSeconds: 2.4)],
            samples: samples
        )
        #expect(text == "Привет, мир.")
    }

    @Test("та же фраза внутри слышимой речи остаётся")
    func samePhraseInsideAudibleSpeechIsKept() {
        // Звук идёт до 2.6 с, сегмент начался в 2.3 с: человек сказал это сам.
        let samples = Self.speech(seconds: 2.6) + Self.silence(seconds: 1)
        let text = TrailingHallucinationFilter.filtering(
            rawText: "Привет, мир. Thank you.",
            segments: [Segment(text: "Привет, мир.", startSeconds: 0), Segment(text: " Thank you.", startSeconds: 2.3)],
            samples: samples
        )
        #expect(text == "Привет, мир. Thank you.")
    }

    @Test("без долгой тишины в конце текст не трогается")
    func noLongSilenceKeepsText() {
        let samples = Self.speech(seconds: 2) + Self.silence(seconds: 0.2)
        let text = TrailingHallucinationFilter.filtering(
            rawText: "Привет, мир. Thank you.",
            segments: [Segment(text: "Привет, мир.", startSeconds: 0), Segment(text: " Thank you.", startSeconds: 2.1)],
            samples: samples
        )
        #expect(text == "Привет, мир. Thank you.")
    }

    @Test("снимаются все подряд идущие концовки, речь перед ними остаётся")
    func severalTrailingSegmentsAreRemoved() {
        let samples = Self.speech(seconds: 2) + Self.silence(seconds: 2)
        let text = TrailingHallucinationFilter.filtering(
            rawText: "Раз два. Thank you. Thank you.",
            segments: [
                Segment(text: "Раз два.", startSeconds: 0),
                Segment(text: " Thank you.", startSeconds: 2.3),
                Segment(text: " Thank you.", startSeconds: 3.1),
            ],
            samples: samples
        )
        #expect(text == "Раз два.")
    }

    @Test("сегменты лекции: концовка после речи снимается по звуку")
    func lectureSegmentsDropTrailingSegmentsAfterSpeech() {
        let segments = [
            TranscribedSegment(text: "Первая мысль.", startSeconds: 0, endSeconds: 2),
            TranscribedSegment(text: "Thank you.", startSeconds: 2.4, endSeconds: 3),
        ]
        let cleaned = WhisperKitTranscriber.cleanedSegments(
            from: segments,
            hadLongTrailingSilence: true,
            lastAudibleSecond: 2.0
        )
        #expect(cleaned.map(\.text) == ["Первая мысль."])
    }

    @Test("сегменты лекции: без звукового свидетельства остаются")
    func lectureSegmentsKeepEverythingWithoutAudioEvidence() {
        let segments = [
            TranscribedSegment(text: "Первая мысль.", startSeconds: 0, endSeconds: 2),
            TranscribedSegment(text: "Thank you.", startSeconds: 2.4, endSeconds: 3),
        ]
        let cleaned = WhisperKitTranscriber.cleanedSegments(
            from: segments,
            hadLongTrailingSilence: false,
            lastAudibleSecond: 2.0
        )
        #expect(cleaned.count == 2)
    }
}
