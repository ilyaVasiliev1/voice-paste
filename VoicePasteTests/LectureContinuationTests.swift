import XCTest

@testable import VoicePaste

/// Требование «Запись продолжает сохранённую лекцию».
@MainActor
final class LectureContinuationTests: XCTestCase {

    func test_checkpointAndFinalUseSameID_andFinalClearsIncomplete() {
        let now = Date(timeIntervalSince1970: 100)
        let session = LectureRecordingSession(startedAt: now)
        let paragraphs = [LectureParagraph(text: "A thought", startSeconds: 0, endSeconds: 2)]
        let checkpoint = session.detail(paragraphs: paragraphs, sampleCount: 32_000,
            language: "en", issue: "incomplete", now: now, title: "Lecture")
        let final = session.detail(paragraphs: paragraphs, sampleCount: 48_000,
            language: "en", issue: nil, now: now, title: "Lecture")
        XCTAssertEqual(checkpoint.lecture.id, final.lecture.id)
        XCTAssertEqual(checkpoint.lecture.transcriptionIssue, "incomplete")
        XCTAssertNil(final.lecture.transcriptionIssue)
        XCTAssertEqual(final.lecture.durationMilliseconds, 3_000)
    }

    func test_checkpointFirstTextIsImmediate_thenAtMostEveryFifteenSeconds() {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(LectureRecordingSession.checkpointDue(hasText: false, lastCheckpoint: nil, now: now))
        XCTAssertTrue(LectureRecordingSession.checkpointDue(hasText: true, lastCheckpoint: nil, now: now))
        XCTAssertFalse(LectureRecordingSession.checkpointDue(hasText: true, lastCheckpoint: now, now: now.addingTimeInterval(14)))
        XCTAssertTrue(LectureRecordingSession.checkpointDue(hasText: true, lastCheckpoint: now, now: now.addingTimeInterval(15)))
    }

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
