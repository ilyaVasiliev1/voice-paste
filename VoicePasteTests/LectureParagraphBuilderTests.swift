import XCTest

@testable import VoicePaste

/// Требование «Абзацы нарезаются по паузам говорящего» и инвариант порога.
///
/// Это единственное правило оформления в учебном режиме, и оно чистое —
/// значит доказывается целиком, хотя экран вокруг него тестами не покрыт.
@MainActor
final class LectureParagraphBuilderTests: XCTestCase {

    private func segment(_ text: String, _ start: Double, _ end: Double) -> TranscribedSegment {
        TranscribedSegment(text: text, startSeconds: start, endSeconds: end)
    }

    // MARK: - Нарезка

    func test_pauseLongerThanThreshold_startsANewParagraph() {
        let segments = [
            segment("Сегодня разберём модель актора.", 0, 4),
            segment("Вернёмся к примеру со счётом.", 9, 13),
        ]

        let paragraphs = LectureParagraphBuilder.build(from: segments, pauseSeconds: 2)

        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertEqual(paragraphs[0].text, "Сегодня разберём модель актора.")
        XCTAssertEqual(paragraphs[1].text, "Вернёмся к примеру со счётом.")
    }

    func test_pauseShorterThanThreshold_keepsTheSameParagraph() {
        let segments = [
            segment("Сегодня разберём модель актора.", 0, 4),
            segment("Это способ описать конкурентность.", 4.5, 8),
        ]

        let paragraphs = LectureParagraphBuilder.build(from: segments, pauseSeconds: 2)

        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertEqual(
            paragraphs[0].text,
            "Сегодня разберём модель актора. Это способ описать конкурентность."
        )
    }

    /// Ровно порог — ещё новый абзац: граница включительная, иначе поведение
    /// на точном значении настройки было бы неопределённым.
    func test_pauseExactlyAtThreshold_startsANewParagraph() {
        let segments = [
            segment("Первое.", 0, 4),
            segment("Второе.", 6, 8),
        ]

        let paragraphs = LectureParagraphBuilder.build(from: segments, pauseSeconds: 2)

        XCTAssertEqual(paragraphs.count, 2)
    }

    // MARK: - Время абзаца

    func test_paragraphSpansFromItsFirstSegmentToItsLast() {
        let segments = [
            segment("Раз.", 1, 3),
            segment("Два.", 3.5, 7),
            segment("Три.", 20, 24),
        ]

        let paragraphs = LectureParagraphBuilder.build(from: segments, pauseSeconds: 2)

        XCTAssertEqual(paragraphs[0].startSeconds, 1)
        XCTAssertEqual(paragraphs[0].endSeconds, 7)
        XCTAssertEqual(paragraphs[1].startSeconds, 20)
        XCTAssertEqual(paragraphs[1].endSeconds, 24)
    }

    // MARK: - Пустое

    func test_emptySegments_produceNoParagraphs() {
        let segments = [
            segment("   ", 0, 4),
            segment("", 5, 6),
        ]

        XCTAssertTrue(LectureParagraphBuilder.build(from: segments, pauseSeconds: 2).isEmpty)
    }

    func test_noSegments_produceNoParagraphs() {
        XCTAssertTrue(LectureParagraphBuilder.build(from: [], pauseSeconds: 2).isEmpty)
    }

    /// Пустой сегмент между двумя непустыми не должен рвать абзац сам по себе:
    /// паузу считает время следующего непустого сегмента.
    func test_emptySegmentBetweenTwo_doesNotSplitTheParagraphByItself() {
        let segments = [
            segment("Раз.", 0, 4),
            segment("", 4, 4.5),
            segment("Два.", 4.5, 8),
        ]

        let paragraphs = LectureParagraphBuilder.build(from: segments, pauseSeconds: 2)

        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertEqual(paragraphs[0].text, "Раз. Два.")
    }

    /// Сегменты приходят из перекрывающихся окон: время следующего окна
    /// может начаться раньше конца принятого. Прежде такая отрицательная
    /// «пауза» продолжала абзац, и вся лекция сливалась в одно полотно.
    func test_segmentFromAnOverlappingWindow_startsANewParagraph() {
        let segments = [
            segment("Конец первого окна.", 0, 10),
            segment("Начало второго окна.", 9, 13),
        ]

        let paragraphs = LectureParagraphBuilder.build(from: segments, pauseSeconds: 2)

        XCTAssertEqual(paragraphs.count, 2, "Стык окон обязан давать разрыв абзаца")
        XCTAssertEqual(paragraphs[1].text, "Начало второго окна.")
    }

    // MARK: - Порог

    func test_pauseBelowRange_isClampedToTheMinimum() {
        XCTAssertEqual(LectureParagraphBuilder.clampPause(0.1), 1)
    }

    func test_pauseAboveRange_isClampedToTheMaximum() {
        XCTAssertEqual(LectureParagraphBuilder.clampPause(99), 10)
    }

    func test_defaultPause_isInsideTheAllowedRange() {
        XCTAssertTrue(
            LectureParagraphBuilder.pauseRange.contains(LectureParagraphBuilder.defaultPauseSeconds)
        )
    }

    /// Порог из настройки приходит уже приведённым, но сборщик обязан устоять
    /// и на сыром значении — иначе один кривой ввод превращает лекцию в
    /// сплошное полотно или в россыпь однострочных абзацев.
    func test_outOfRangePause_isAppliedAsClamped() {
        let segments = [
            segment("Раз.", 0, 4),
            segment("Два.", 5, 8),
        ]

        // Сырой порог 0.1 привёлся бы к 1 с: пауза в 1 с — новый абзац.
        let paragraphs = LectureParagraphBuilder.build(from: segments, pauseSeconds: 0.1)

        XCTAssertEqual(paragraphs.count, 2)
    }
}
