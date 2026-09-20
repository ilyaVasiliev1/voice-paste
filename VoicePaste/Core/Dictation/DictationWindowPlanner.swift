/// Решает, какой отрезок записи пора распознавать, пока запись ещё идёт.
///
/// Замер скорости (`docs/status.md`) показал: распознавание съедает около 7 %
/// реального времени, но платит около полусекунды постоянной накладной за
/// вызов. Отсюда правило: короткую запись резать нельзя — накладная будет
/// уплачена несколько раз вместо одного, — а длинную выгодно считать по ходу,
/// чтобы после остановки остался только хвост.
///
/// Тип чистый и не знает ни про звук, ни про модель: он считает границы. Это
/// единственный способ доказать нарезку тестами — живой `AVAudioEngine` в
/// тестах не поднимается.
nonisolated struct DictationWindowPlanner: Sendable {

    /// Длина окна. Совпадает с окном тракта импорта: там та же нарезка уже
    /// отработана и покрыта тестами.
    let windowSamples: Int

    /// Насколько следующее окно заходит на предыдущее. Нужно, чтобы слово на
    /// границе попало в оба окна и склейка смогла убрать повтор.
    let overlapSamples: Int

    /// Конец последнего выданного окна. Следующее начнётся раньше него на
    /// величину перекрытия.
    private(set) var plannedUpTo: Int = 0

    init(windowSamples: Int, overlapSamples: Int) {
        precondition(windowSamples > 0, "Окно нулевой длины не нарезает ничего")
        precondition(
            overlapSamples >= 0 && overlapSamples < windowSamples,
            "Перекрытие шире окна зацикливает нарезку, отрицательное — рвёт запись"
        )
        self.windowSamples = windowSamples
        self.overlapSamples = overlapSamples
    }

    /// Следующее закрывшееся окно, если накопленного звука на него хватает.
    /// `nil` означает «рано» — и для короткой записи так и останется.
    mutating func nextClosedWindow(availableSamples: Int) -> Range<Int>? {
        let start = nextWindowStart
        let end = start + windowSamples
        guard end <= availableSamples else { return nil }
        plannedUpTo = end
        return start..<end
    }

    /// Незакрытый хвост после остановки записи. `nil`, если хвоста нет —
    /// последнее окно закрылось ровно на конце записи.
    ///
    /// Когда не было выдано ни одного окна, возвращается вся запись: короткая
    /// диктовка распознаётся одним проходом, как и до появления нарезки.
    mutating func finalTail(totalSamples: Int) -> Range<Int>? {
        let start = nextWindowStart
        guard start < totalSamples else { return nil }
        plannedUpTo = totalSamples
        return start..<totalSamples
    }

    /// Начало следующего отрезка. До первого окна — ноль, дальше — конец
    /// предыдущего, сдвинутый назад на перекрытие.
    private var nextWindowStart: Int {
        plannedUpTo == 0 ? 0 : plannedUpTo - overlapSamples
    }
}
