import XCTest

@testable import VoicePaste

/// Инвариант «Окна записи нарезаются подряд, с перекрытием и без пропусков».
///
/// Планировщик чистый, поэтому нарезка проверяется целиком — включая то, что
/// живой звук проверить не даёт: покрытие записи без дыр на произвольных
/// длинах.
@MainActor
final class DictationWindowPlannerTests: XCTestCase {

    private let window = 100
    private let overlap = 10

    private func makePlanner() -> DictationWindowPlanner {
        DictationWindowPlanner(windowSamples: window, overlapSamples: overlap)
    }

    // MARK: - Короткая запись не режется

    func test_recordingShorterThanOneWindow_producesNoClosedWindows() {
        var planner = makePlanner()

        XCTAssertNil(planner.nextClosedWindow(availableSamples: window - 1))
    }

    func test_recordingShorterThanOneWindow_isTranscribedWholeAsTheTail() {
        var planner = makePlanner()
        XCTAssertNil(planner.nextClosedWindow(availableSamples: 42))

        let tail = planner.finalTail(totalSamples: 42)

        XCTAssertEqual(tail, 0..<42, "Короткая диктовка обязана идти одним проходом")
    }

    // MARK: - Закрывшиеся окна

    func test_firstWindowStartsAtZero_andClosesExactlyAtWindowLength() {
        var planner = makePlanner()

        XCTAssertEqual(planner.nextClosedWindow(availableSamples: window), 0..<window)
    }

    func test_secondWindowStepsBackByTheOverlap() {
        var planner = makePlanner()
        _ = planner.nextClosedWindow(availableSamples: window)

        let second = planner.nextClosedWindow(availableSamples: window * 2)

        XCTAssertEqual(second, (window - overlap)..<(window - overlap + window))
    }

    func test_windowIsNotProducedUntilEnoughAudioHasArrived() {
        var planner = makePlanner()
        _ = planner.nextClosedWindow(availableSamples: window)

        // Второму окну нужно `window - overlap + window` сэмплов; на один
        // меньше — ещё рано.
        XCTAssertNil(planner.nextClosedWindow(availableSamples: window * 2 - overlap - 1))
    }

    // MARK: - Хвост

    func test_tailRunsFromTheOverlapOfTheLastWindowToTheEnd() {
        var planner = makePlanner()
        _ = planner.nextClosedWindow(availableSamples: window)

        let tail = planner.finalTail(totalSamples: window + 30)

        XCTAssertEqual(tail, (window - overlap)..<(window + 30))
    }

    func test_noTailWhenTheLastWindowClosedExactlyAtTheEnd() {
        var planner = makePlanner()
        _ = planner.nextClosedWindow(availableSamples: window)

        XCTAssertNil(planner.finalTail(totalSamples: window - overlap))
    }

    // MARK: - Покрытие без дыр

    /// Главное свойство: объединение всех выданных отрезков обязано покрыть
    /// запись целиком. Дыра означает потерянные слова, и заметить её на слух
    /// почти невозможно — поэтому проверяется перебором длин.
    func test_everyRecordingLength_isCoveredWithoutGaps() {
        for total in stride(from: 1, through: window * 5, by: 7) {
            var planner = makePlanner()
            var covered: [Range<Int>] = []
            while let piece = planner.nextClosedWindow(availableSamples: total) {
                covered.append(piece)
            }
            if let tail = planner.finalTail(totalSamples: total) {
                covered.append(tail)
            }

            XCTAssertFalse(covered.isEmpty, "Длина \(total): не выдано ни одного отрезка")
            XCTAssertEqual(covered.first?.lowerBound, 0, "Длина \(total): начало не покрыто")
            XCTAssertEqual(covered.last?.upperBound, total, "Длина \(total): конец не покрыт")
            for (earlier, later) in zip(covered, covered.dropFirst()) {
                XCTAssertLessThanOrEqual(
                    later.lowerBound, earlier.upperBound,
                    "Длина \(total): дыра между \(earlier) и \(later)"
                )
            }
        }
    }

    /// Перекрытие обязано быть настоящим: без него слово на границе рвётся, а
    /// склейке нечего будет сопоставить.
    func test_consecutiveWindowsActuallyOverlap() {
        var planner = makePlanner()
        var covered: [Range<Int>] = []
        while let piece = planner.nextClosedWindow(availableSamples: window * 4) {
            covered.append(piece)
        }

        XCTAssertGreaterThan(covered.count, 1)
        for (earlier, later) in zip(covered, covered.dropFirst()) {
            XCTAssertEqual(earlier.upperBound - later.lowerBound, overlap)
        }
    }
}
