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
        static let minHeight: CGFloat = 190
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
        /// Красная точка «идёт запись» рядом с таймером.
        static let statusDot: CGFloat = 8
        /// Маркер строки живого текста лекции.
        static let liveMarker: CGFloat = 6
    }

    /// Минимальная высота области графика статистики.
    static let chartMinHeight: CGFloat = 210

    /// Карточка: показатели и график статистики, строка очереди в статистике.
    /// Прежде 10 и 12 без причины.
    static let cardCornerRadius: CGFloat = 12

    /// Предельная ширина текста записи: длиннее строка читается тяжело.
    static let readingMeasure: CGFloat = 680

    /// Ширина подписи значения у ползунка в настройках: «2,0 с», «30 с».
    static let sliderValueWidth: CGFloat = 56

    /// Предельная ширина экрана-формы (импорт): шире зона приёма растягивается без пользы.
    static let formMeasure: CGFloat = 860

    /// Внешний отступ правой части главного окна. Два экрана из четырёх уже
    /// держали 24 — остальные подведены под них.
    static let detailPanePadding: CGFloat = Spacing.xl
}

extension View {
    func cardSurface() -> some View {
        modifier(CardSurface())
    }
}

private struct CardSurface: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius, style: .continuous)
        content
            .background(Color(nsColor: .controlBackgroundColor), in: shape)
            .overlay { shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 1) }
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

    /// Существительное при числе: «1 слово», «2 слова», «5 слов», «21 слово».
    private static func plural(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        let lastTwo = abs(count) % 100
        let last = abs(count) % 10
        let form: String
        if (11...14).contains(lastTwo) { form = many }
        else if last == 1 { form = one }
        else if (2...4).contains(last) { form = few }
        else { form = many }
        return "\(count) \(form)"
    }

    static func words(_ count: Int) -> String { plural(count, "слово", "слова", "слов") }

    static func transcriptions(_ count: Int) -> String { plural(count, "расшифровка", "расшифровки", "расшифровок") }

    /// Длительность с единицами на всех экранах: «6 с», «1 мин 35 с», «46 мин», «1 ч 12 мин».
    static func duration(milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1_000)
        if seconds < 60 { return "\(seconds) с" }
        if seconds < 600 {
            let rest = seconds % 60
            return rest == 0 ? "\(seconds / 60) мин" : "\(seconds / 60) мин \(rest) с"
        }
        if seconds < 3_600 { return "\(seconds / 60) мин" }
        let minutes = (seconds % 3_600) / 60
        return minutes == 0 ? "\(seconds / 3_600) ч" : "\(seconds / 3_600) ч \(minutes) мин"
    }

    /// Строка над графиком: дата и итоги дня, либо «Нет записей».
    static func dayUsage(dateText: String, words wordCount: Int, transcriptions count: Int, durationMilliseconds: Int) -> String {
        guard wordCount > 0 || count > 0 else { return "\(dateText) · Нет записей" }
        return "\(dateText) · \(words(wordCount)) · \(transcriptions(count)) · \(duration(milliseconds: durationMilliseconds))"
    }

    /// Название языка словом, а не кодом: «Русский», не «RU».
    static func languageName(_ code: String?, locale: Locale = .current) -> String? {
        guard let code, let name = locale.localizedString(forLanguageCode: code), let first = name.first else { return nil }
        return first.uppercased() + name.dropFirst()
    }
}

nonisolated enum WorkspacePalette {
    static let sidebar = adaptive(light: 0.965, dark: 0.115)
    static let list = adaptive(light: 0.992, dark: 0.135)
    static let document = adaptive(light: 1, dark: 0.15)
    static let selection = adaptive(light: 0.915, dark: 0.23)
    static let hover = adaptive(light: 0.94, dark: 0.19)
    static let line = Color.primary.opacity(0.085)

    private static func adaptive(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(white: isDark ? dark : light, alpha: 1)
        })
    }
}

struct WorkspaceRowStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        WorkspaceRowBody(configuration: configuration, selected: selected)
    }

    private struct WorkspaceRowBody: View {
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        @State private var hovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(selected || configuration.isPressed ? WorkspacePalette.selection : hovered ? WorkspacePalette.hover : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}

struct WorkspaceActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(primary ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(primary ? Color.accentColor.opacity(configuration.isPressed ? 0.7 : 1) : WorkspacePalette.hover,
                        in: RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

struct WorkspaceHeader<Actions: View>: View {
    let title: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
        .overlay(alignment: .bottom) { WorkspacePalette.line.frame(height: 1) }
    }
}
