import CoreFoundation

/// Ширины главного окна и его колонок — в одном месте и с одной зависимостью
/// между ними.
///
/// Инвариант «Минимум главного окна вмещает обе его колонки»: минимум окна
/// **выводится** из ширин колонок и не задаётся отдельным числом. Пока он был
/// отдельным (680 при колонках 240 и 520), условия раскладки не имели решения
/// уже в исходном положении: правой части было некуда сжиматься, и растягивание
/// боковой панели ломало окно.
enum MainWindowLayout {

    /// Боковая панель: список записей и поиск.
    static let sidebarMinWidth: CGFloat = 240
    static let sidebarIdealWidth: CGFloat = 300
    static let sidebarMaxWidth: CGFloat = 380

    /// Правая часть: деталь записи, статистика или очередь импорта. Диаграммы
    /// статистики — самое широкое из этого, они и задают предел.
    static let detailMinWidth: CGFloat = 520

    /// Выведенная величина. Менять её отдельно нельзя — только через ширины
    /// колонок, из которых она складывается.
    static let windowMinWidth: CGFloat = sidebarMinWidth + detailMinWidth

    static let windowMinHeight: CGFloat = 460

    /// Вмещает раскрытую до предела панель рядом с правой частью на минимуме.
    static let defaultWindowWidth: CGFloat = 980
    static let defaultWindowHeight: CGFloat = 640
}
