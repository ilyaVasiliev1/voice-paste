import Foundation
import Testing

@testable import VoicePaste

/// Детектор на настоящей записи речи (приватная фикстура, в git не входит).
/// Там, где её нет, тест пропускается — как остальные тесты на фикстуры.
@Suite("Детектор речи на настоящей записи")
struct SpeechGateRealSpeechTests {

    private static let fixture = TestFixtureLocator.url(
        for: "TelegramOGG/sample-01.ogg",
        sourceFile: #filePath
    )

    @Test(
        "речь на записи 132 с найдена, окна по секунде почти не теряются",
        .enabled(if: SpeechGateRealSpeechTests.fixture != nil, "нет приватной фикстуры sample-01.ogg")
    )
    func realSpeechIsFound() async throws {
        let url = try #require(Self.fixture)
        let samples = try await AudioDecoder().decode(url: url)

        let whole = SpeechGate.analyze(samples)
        #expect(whole.hasSpeech)
        // Измерено 14.10.2026: 102,9 с речи из 132,4 с записи.
        #expect((90...115).contains(whole.speechSeconds))

        // Окна по секунде с заметной громкостью: речь теряться не должна.
        // Измерено: 0,2 % окон с средней громкостью не ниже 0,01.
        let window = 16_000
        var counted = 0
        var missed = 0
        var start = 0
        while start + window <= samples.count {
            let slice = Array(samples[start..<(start + window)])
            let mean = slice.reduce(0) { $0 + abs($1) } / Float(window)
            if mean >= 0.005 {
                counted += 1
                if !SpeechGate.analyze(slice).hasSpeech { missed += 1 }
            }
            start += window
        }
        #expect(counted > 50)
        #expect(Double(missed) / Double(counted) <= 0.02)
    }
}
