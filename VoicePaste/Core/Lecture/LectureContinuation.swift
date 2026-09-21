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
