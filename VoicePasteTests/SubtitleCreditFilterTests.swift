import XCTest

@testable import VoicePaste

/// Требование «Выдуманные титры о субтитрах снимаются в любом месте».
@MainActor
final class SubtitleCreditFilterTests: XCTestCase {

    func test_creditLine_isRecognized_realSpeechIsNot() {
        for credit in [
            "Субтитры делал DimaTorzok",
            "Субтитры сделал DimaTorzok.",
            "Редактор субтитров А.Семкин Корректор А.Егорова",
            "Субтитры создавал DimaTorzok",
            "Subtitles by the Amara.org community",
        ] {
            XCTAssertTrue(SubtitleCreditFilter.isCredit(credit), credit)
        }
        for speech in [
            "Включи субтитры к этому видео",
            "Это мистика, что ли? Все хотят лишь одного.",
            "Продолжение следует",
        ] {
            XCTAssertFalse(SubtitleCreditFilter.isCredit(speech), speech)
        }
    }

    func test_creditSegment_removedFromTheMiddle() {
        let segments = [
            TranscribedSegment(text: "ПЕСНЯ", startSeconds: 0, endSeconds: 4),
            TranscribedSegment(text: "Субтитры делал DimaTorzok", startSeconds: 5, endSeconds: 9),
            TranscribedSegment(text: "Это мистика, что ли?", startSeconds: 15, endSeconds: 19),
        ]

        let cleaned = WhisperKitTranscriber.cleanedSegments(from: segments, hadLongTrailingSilence: false)

        XCTAssertEqual(cleaned.map(\.text), ["ПЕСНЯ", "Это мистика, что ли?"])
    }

    func test_creditRemovedFromDictationText() {
        let text = SubtitleCreditFilter.removingCredits(
            from: "Купить молоко. Субтитры делал DimaTorzok",
            segmentTexts: ["Купить молоко.", "Субтитры делал DimaTorzok"]
        )

        XCTAssertEqual(text, "Купить молоко.")
    }
}
