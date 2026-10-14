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
        /// Уход короче прихода: Telegram держит 150 мс против 200 на показ.
        static let exit: Double = 0.12

        /// Множитель времени для осмотра движения кадрами: `VOICEPASTE_MOTION_SLOWDOWN=8`
        /// растягивает каждое движение в 8 раз. В обычной работе — 1.
        static let timeScale: Double = {
            let raw = ProcessInfo.processInfo.environment["VOICEPASTE_MOTION_SLOWDOWN"]
            return raw.flatMap(Double.init).flatMap { $0 >= 1 ? $0 : nil } ?? 1
        }()

        private static func scaled(_ animation: Animation) -> Animation {
            timeScale == 1 ? animation : animation.speed(1 / timeScale)
        }

        /// Растворение и смена цвета: отклик, которого не должно быть видно.
        static let fade = scaled(.easeOut(duration: quick))
        /// Прокрутка за текстом, который пишется: пружина несёт скорость при каждом новом куске.
        static let scroll = scaled(.smooth(duration: 0.25))
        /// Размер плашки: плавная пружина без отскока. Успевает прерваться на лету —
        /// пружина несёт скорость при перенацеливании, а `easeInOut` стартовал бы с нуля.
        static let surfaceDuration: Double = 0.28
        static let surface = scaled(.smooth(duration: surfaceDuration))
        /// Смена содержимого плашки: старое уходит раньше, чем контейнер заметно
        /// сжался, новое появляется после него. Иначе крестик остаётся в сжавшейся панели.
        static let contentOutDuration: Double = 0.07
        static let contentInDuration: Double = 0.16
        /// Пауза между уходом старого и приходом нового: капсула успевает дорасти,
        /// и новое содержимое не режется её краем на ходу.
        static let contentGap: Double = 0.10

        /// «Уменьшить движение»: любое движение заменяется коротким растворением.
        static func respecting(_ animation: Animation, reduceMotion: Bool) -> Animation {
            reduceMotion ? fade : animation
        }
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

    /// Предельная ширина текста записи: длиннее строка читается тяжело.
    static let readingMeasure: CGFloat = 680

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

/// Даты и языки в списках и шапках: одна форма на все экраны.
nonisolated enum DisplayFormat {
    /// Сегодня и вчера — словами со временем, в этом году — без года, раньше — с годом
    /// и без времени: точное время давней записи ничего не говорит.
    static func recordDate(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let time = date.formatted(Date.FormatStyle(
            date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone
        ))
        if calendar.isDate(date, inSameDayAs: now) {
            return NSLocalizedString("date.today", value: "Сегодня", comment: "") + ", " + time
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return NSLocalizedString("date.yesterday", value: "Вчера", comment: "") + ", " + time
        }
        let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .day().month(.abbreviated)
        if sameYear { return date.formatted(style) + ", " + time }
        style = style.year()
        return date.formatted(style)
    }

    /// Название языка словом, а не кодом: «Русский», не «RU».
    static func languageName(_ code: String?, locale: Locale = .current) -> String? {
        guard let code, let name = locale.localizedString(forLanguageCode: code), let first = name.first else { return nil }
        return first.uppercased() + name.dropFirst()
    }
}
