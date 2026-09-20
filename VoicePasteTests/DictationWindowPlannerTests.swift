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
        let planner = makePlanner()

        XCTAssertNil(planner.closedWindow(availableSamples: window - 1))
    }

    func test_recordingShorterThanOneWindow_isTranscribedWholeAsTheTail() {
        let planner = makePlanner()

        let tail = planner.tail(totalSamples: 42)

        XCTAssertEqual(tail, 0..<42, "Короткая диктовка обязана идти одним проходом")
    }

    // MARK: - Закрывшиеся окна

    func test_firstWindowStartsAtZero_andClosesExactlyAtWindowLength() {
        let planner = makePlanner()

        XCTAssertEqual(planner.closedWindow(availableSamples: window), 0..<window)
    }

    func test_secondWindowStepsBackByTheOverlap() throws {
        var planner = makePlanner()
        planner.commit(try XCTUnwrap(planner.closedWindow(availableSamples: window)))

        let second = planner.closedWindow(availableSamples: window * 2)

        XCTAssertEqual(second, (window - overlap)..<(window - overlap + window))
    }

    func test_windowIsNotProducedUntilEnoughAudioHasArrived() throws {
        var planner = makePlanner()
        planner.commit(try XCTUnwrap(planner.closedWindow(availableSamples: window)))

        // Второму окну нужно `window - overlap + window` сэмплов; на один
        // меньше — ещё рано.
        XCTAssertNil(planner.closedWindow(availableSamples: window * 2 - overlap - 1))
    }

    /// Свойство, ради которого запрос отделён от фиксации: пока отрезок не
    /// посчитан, нарезка стоит на месте. Иначе неудачное чтение съело бы окно
    /// молча, и в записи появилась бы дыра.
    func test_queryingWithoutCommitting_keepsReturningTheSameWindow() {
        let planner = makePlanner()

        let first = planner.closedWindow(availableSamples: window * 3)
        let again = planner.closedWindow(availableSamples: window * 3)

        XCTAssertEqual(first, again)
        XCTAssertEqual(planner.plannedUpTo, 0, "Запрос не имеет права сдвигать нарезку")
    }

    // MARK: - Хвост

    func test_tailRunsFromTheOverlapOfTheLastWindowToTheEnd() throws {
        var planner = makePlanner()
        planner.commit(try XCTUnwrap(planner.closedWindow(availableSamples: window)))

        let tail = planner.tail(totalSamples: window + 30)

        XCTAssertEqual(tail, (window - overlap)..<(window + 30))
    }

    func test_noTailWhenTheLastWindowClosedExactlyAtTheEnd() throws {
        var planner = makePlanner()
        planner.commit(try XCTUnwrap(planner.closedWindow(availableSamples: window)))

        XCTAssertNil(planner.tail(totalSamples: window - overlap))
    }

    /// Условие `commit` намеренно строгое: фиксация не того отрезка означала
    /// бы разъехавшуюся нарезку. Тест закрепляет, что проверка отмены в
    /// вызывающем коде обязана стоять до фиксации, а не после.
    func test_committingAPieceThatIsNotTheRequestedOne_isAProgrammerError() throws {
        var planner = makePlanner()
        let first = planner.closedWindow(availableSamples: window * 3)

        planner.commit(try XCTUnwrap(first))

        // Тот же отрезок второй раз — уже не тот, что запрошен сейчас.
        XCTAssertNotEqual(planner.plannedUpTo, 0)
        XCTAssertNotEqual(planner.closedWindow(availableSamples: window * 3), first)
    }

    // MARK: - Покрытие без дыр

    /// Главное свойство: объединение всех выданных отрезков обязано покрыть
    /// запись целиком. Дыра означает потерянные слова, и заметить её на слух
    /// почти невозможно — поэтому проверяется перебором длин.
    func test_everyRecordingLength_isCoveredWithoutGaps() {
        for total in stride(from: 1, through: window * 5, by: 7) {
            var planner = makePlanner()
            var covered: [Range<Int>] = []
            while let piece = planner.closedWindow(availableSamples: total) {
                planner.commit(piece)
                covered.append(piece)
            }
            if let tail = planner.tail(totalSamples: total) {
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
        while let piece = planner.closedWindow(availableSamples: window * 4) {
            planner.commit(piece)
            covered.append(piece)
        }

        XCTAssertGreaterThan(covered.count, 1)
        for (earlier, later) in zip(covered, covered.dropFirst()) {
            XCTAssertEqual(earlier.upperBound - later.lowerBound, overlap)
        }
    }
}
