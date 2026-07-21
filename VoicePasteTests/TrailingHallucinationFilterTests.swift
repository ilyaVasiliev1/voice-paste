import XCTest
@testable import VoicePaste

final class TrailingHallucinationFilterTests: XCTestCase {
    func test_removesModelTerminalFillerOnlyInTrailingSilence() {
        let samples = Array(repeating: Float(0.05), count: 16_000 * 3)
            + Array(repeating: Float.zero, count: 16_000 * 2)
        let result = TrailingHallucinationFilter.filtering(
            rawText: "Полезный текст. Продолжение следует...",
            segments: [
                .init(text: " Полезный текст.", startSeconds: 0),
                .init(text: " Продолжение следует...", startSeconds: 3.4),
            ],
            samples: samples
        )

        XCTAssertEqual(result, "Полезный текст.")
    }

    func test_removesExactReservedTerminalFillerWhenTimingIsAmbiguous() {
        let samples = Array(repeating: Float(0.05), count: 16_000 * 4)
        let result = TrailingHallucinationFilter.filtering(
            rawText: "На этом всё. Продолжение следует.",
            segments: [
                .init(text: " На этом всё.", startSeconds: 0),
                .init(text: " Продолжение следует.", startSeconds: 2.8),
            ],
            samples: samples
        )

        XCTAssertEqual(result, "На этом всё.")
    }

    func test_removesTerminalFillerWithoutSeparateSegment() {
        let result = TrailingHallucinationFilter.filtering(
            rawText: "Save time with this feature. Продолжение следует...",
            segments: [
                .init(text: " Save time with this feature. Продолжение следует...", startSeconds: 0),
            ],
            samples: Array(repeating: Float(0.05), count: 16_000 * 5)
        )

        XCTAssertEqual(result, "Save time with this feature.")
    }

    func test_trimsOnlyLongTrailingSilenceBeforeWhisper() {
        let spoken = Array(repeating: Float(0.05), count: 16_000)
        let trailingSilence = Array(repeating: Float.zero, count: 16_000 * 2)
        let trimmed = TrailingHallucinationFilter.trimmingLongTrailingSilence(
            from: spoken + trailingSilence
        )

        XCTAssertEqual(trimmed.count, 16_000 + 4_000)
    }
}
