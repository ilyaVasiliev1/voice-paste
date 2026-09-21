import XCTest

@testable import VoicePaste

/// Требование «Запись продолжает сохранённую лекцию».
@MainActor
final class LectureContinuationTests: XCTestCase {

    private let lectureID = UUID()

    private var saved: LectureDetail {
        LectureDetail(
            lecture: Lecture(
                id: lectureID, createdAt: 1_000, updatedAt: 1_000, title: "Параллельное программирование",
                durationMilliseconds: 46 * 60_000, language: "zh", wordCount: 2
            ),
            paragraphs: [
                StoredLectureParagraph(
                    id: UUID(), lectureID: lectureID, orderIndex: 0,
                    startMilliseconds: 0, endMilliseconds: 4_000, text: "первый абзац"
                ),
            ]
        )
    }

    func test_newParagraphs_followTheLectureInTimeAndOrder() {
        let continued = LectureContinuation.appending(
            [LectureParagraph(text: "после перерыва три слова", startSeconds: 5, endSeconds: 9)],
            recordedMilliseconds: 60_000,
            to: saved,
            now: 9_999
        )

        XCTAssertEqual(continued.paragraphs.map(\.text), ["первый абзац", "после перерыва три слова"])
        let added = continued.paragraphs[1]
        XCTAssertEqual(added.orderIndex, 1)
        XCTAssertEqual(added.startMilliseconds, 46 * 60_000 + 5_000, "время не продолжилось от конца лекции")
        XCTAssertEqual(added.endMilliseconds, 46 * 60_000 + 9_000)
        XCTAssertEqual(added.lectureID, lectureID)
        XCTAssertEqual(continued.lecture.durationMilliseconds, 47 * 60_000)
        XCTAssertEqual(continued.lecture.wordCount, 6)
        XCTAssertEqual(continued.lecture.title, "Параллельное программирование")
        XCTAssertEqual(continued.lecture.createdAt, 1_000)
        XCTAssertEqual(continued.lecture.updatedAt, 9_999)
    }

    func test_nothingNew_keepsTheLectureUnchanged() {
        let lecture = saved
        XCTAssertEqual(
            LectureContinuation.appending([], recordedMilliseconds: 30_000, to: lecture, now: 9_999),
            lecture
        )
    }
}
