import SwiftUI

/// Значения оформления, на которые ссылаются, а не переписывают числом.
///
/// Заведены после аудита, показавшего пять разных длительностей анимации на
/// пять точек в продукте и одну и ту же зону приёма файла, реализованную
/// дважды с разошедшимися радиусом, пунктиром и цветом рамки. Числа брались
/// на глаз в момент письма — и расходились ровно настолько, насколько никто
/// не смотрел на них рядом.
///
/// Образец взят из самого продукта: `HUDLayout` в `HUDContentView.swift`
/// давно устроен так же, и внутри HUD дисциплина держалась. За его пределами
/// её не было.
///
/// Прежние пометки `TOK-*` в комментариях указывали на токены удалённой
/// спецификации и были хуже голого числа: они создавали впечатление, что
/// источник истины где-то есть.
nonisolated enum DesignTokens {

    /// Длительности движения. Три шага вместо пяти случайных чисел.
    ///
    /// Шкала не из вкуса: `quick` — отклик на наведение, его не должно быть
    /// видно; `standard` — смена состояния поверхности, которую глаз обязан
    /// проследить; `deliberate` — перемещение содержимого, за которым глаз
    /// именно следует.
    enum Motion {
        static let quick: Double = 0.12
        static let standard: Double = 0.18
        static let deliberate: Double = 0.24
    }

    /// Зона приёма файла. Одна пара значений на обе её реализации — в HUD и
    /// в очереди импорта.
    enum DropZone {
        static let cornerRadius: CGFloat = 12
        static let dash: [CGFloat] = [6, 5]
        static let idleStroke = Color.primary.opacity(0.18)
        static let activeFill = Color.accentColor.opacity(0.10)
        static let idleFill = Color.primary.opacity(0.035)

        /// Заливка зоны: под курсором с файлом или в покое.
        static func fill(isTargeted: Bool) -> Color { isTargeted ? activeFill : idleFill }
    }

    /// Шкала отступов — пять шагов по 4.
    ///
    /// До неё в интерфейсе стояло двенадцать разных `spacing:` и одиннадцать
    /// разных `padding`, половина не кратна 4 (3, 5, 7, 9, 14, 18): числа
    /// брались на глаз и расходились. Ноль — не шаг шкалы, а «без отступа»,
    /// и пишется нулём. Плашку диктовки шкала не трогает: у неё свои
    /// `HUDLayout`, и ею владелец доволен.
    enum Spacing {
        /// Подпись к заголовку, строки внутри одной ячейки списка.
        static let xs: CGFloat = 4
        /// Элементы в одном ряду, значок рядом с текстом.
        static let sm: CGFloat = 8
        /// Внутренний отступ карточки, ряды внутри блока.
        static let md: CGFloat = 12
        /// Между блоками одного экрана.
        static let lg: CGFloat = 16
        /// Край детали и окна онбординга.
        static let xl: CGFloat = 24
    }

    /// Крупный значок-приглашение: зона приёма файла. Прежде 29 — вне шкалы
    /// и вне системы.
    enum IconSize {
        static let invitation: CGFloat = 28
    }

    /// Карточка: показатели и график статистики, строка очереди в статистике.
    /// Прежде 10 и 12 без причины.
    static let cardCornerRadius: CGFloat = 12

    /// Внешний отступ правой части главного окна. Два экрана из четырёх уже
    /// держали 24 — остальные подведены под них.
    static let detailPanePadding: CGFloat = Spacing.xl
}

extension View {
    /// Поверхность карточки. На macOS 26 — стекло, как у панели инструментов
    /// и боковой колонки: иначе карточки остаются единственными плоскими
    /// плашками в окне из стекла. До macOS 26 — прежняя плоская заливка.
    func cardSurface() -> some View {
        modifier(CardSurface())
    }
}

private struct CardSurface: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.quaternary, in: shape)
        }
    }
}
