import CoreFoundation

/// Ширины главного окна и его колонок — в одном месте и с одной зависимостью
/// между ними.
///
/// Инвариант «Минимум главного окна вмещает все три его колонки»: минимум
/// окна **выводится** из ширин колонок и не задаётся отдельным числом. Пока он
/// был отдельным (680 при колонках 240 и 520), условия раскладки не имели
/// решения уже в исходном положении: правой части было некуда сжиматься, и
/// растягивание боковой панели ломало окно.
enum MainWindowLayout {

    /// Разделы: четыре строки с подписями.
    static let sidebarMinWidth: CGFloat = 170
    static let sidebarIdealWidth: CGFloat = 190
    static let sidebarMaxWidth: CGFloat = 240

    /// Список раздела: записи с поиском, лекции, очередь, периоды.
    static let listMinWidth: CGFloat = 240
    static let listIdealWidth: CGFloat = 280
    static let listMaxWidth: CGFloat = 340

    /// Деталь: текст записи, лекция, статистика. Диаграммы статистики — самое
    /// широкое из этого, они и задают предел.
    static let detailMinWidth: CGFloat = 520

    /// Выведенная величина. Менять её отдельно нельзя — только через ширины
    /// колонок, из которых она складывается.
    static let windowMinWidth: CGFloat = sidebarMinWidth + listMinWidth + detailMinWidth

    static let windowMinHeight: CGFloat = 460

    /// Вмещает раскрытые до предела разделы и список рядом с деталью на минимуме.
    static let defaultWindowWidth: CGFloat = 1_120
    static let defaultWindowHeight: CGFloat = 680
}
