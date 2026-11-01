import Foundation

/// Дописывание сохранённой лекции новой записью.
///
/// Хранилище перезаписывает лекцию целиком (`LectureStore.save`), поэтому
/// продолжение — это новая версия лекции, собранная здесь: прежние абзацы,
/// за ними новые со временем от конца лекции.
nonisolated public enum LectureContinuation {

    /// - Parameters:
    ///   - paragraphs: абзацы новой записи, время — от её начала.
    ///   - recordedMilliseconds: длительность новой записи.
    public static func appending(
        _ paragraphs: [LectureParagraph],
        recordedMilliseconds: Int,
        to detail: LectureDetail,
        now: Int64
    ) -> LectureDetail {
        guard !paragraphs.isEmpty else { return detail }
        let offset = detail.lecture.durationMilliseconds
        let firstIndex = (detail.paragraphs.map(\.orderIndex).max() ?? -1) + 1
        let added = paragraphs.enumerated().map { index, paragraph in
            StoredLectureParagraph(
                id: UUID(),
                lectureID: detail.lecture.id,
                orderIndex: firstIndex + index,
                startMilliseconds: offset + Int(paragraph.startSeconds * 1_000),
                endMilliseconds: offset + Int(paragraph.endSeconds * 1_000),
                text: paragraph.text
            )
        }
        let allParagraphs = detail.paragraphs + added
        var lecture = detail.lecture
        lecture.durationMilliseconds = offset + recordedMilliseconds
        lecture.wordCount = WordCounting.count(in: allParagraphs.map(\.text).joined(separator: " "))
        lecture.updatedAt = now
        return LectureDetail(lecture: lecture, paragraphs: allParagraphs)
    }
}

nonisolated struct LectureRecordingSession: Sendable {
    let id: UUID
    let startedAt: Date
    let base: LectureDetail?
    var checkpointParagraphs: [LectureParagraph] = []

    init(startedAt: Date, base: LectureDetail? = nil) {
        self.id = base?.lecture.id ?? UUID()
        self.startedAt = startedAt
        self.base = base
    }

    func detail(paragraphs: [LectureParagraph], sampleCount: Int, language: String?,
                issue: String?, now: Date, title: String) -> LectureDetail {
        if let base {
            var result = LectureContinuation.appending(paragraphs,
                recordedMilliseconds: sampleCount * 1_000 / 16_000, to: base,
                now: Int64(now.timeIntervalSince1970 * 1_000))
            result.lecture.transcriptionIssue = issue ?? base.lecture.transcriptionIssue
            return result
        }
        return LectureDetail(lecture: Lecture(id: id,
            createdAt: Int64(startedAt.timeIntervalSince1970 * 1_000),
            updatedAt: Int64(now.timeIntervalSince1970 * 1_000), title: title,
            durationMilliseconds: sampleCount * 1_000 / 16_000, language: language,
            wordCount: WordCounting.count(in: paragraphs.map(\.text).joined(separator: " ")),
            transcriptionIssue: issue),
            paragraphs: paragraphs.enumerated().map { index, paragraph in
                StoredLectureParagraph(id: UUID(), lectureID: id, orderIndex: index,
                    startMilliseconds: Int(paragraph.startSeconds * 1_000),
                    endMilliseconds: Int(paragraph.endSeconds * 1_000), text: paragraph.text)
            })
    }

    static func checkpointDue(hasText: Bool, lastCheckpoint: Date?, now: Date) -> Bool {
        hasText && (lastCheckpoint.map { now.timeIntervalSince($0) >= 15 } ?? true)
    }
}
