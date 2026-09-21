import Foundation

/// Разделы единственного постоянного окна. Каждый владеет списком посередине
/// и деталью справа.
public enum MainContentSection: Hashable, Sendable {
    case lecture
    case history
    case importQueue
    case dashboard

    /// Порядок в колонке разделов — согласован с владельцем.
    static let sidebarOrder: [MainContentSection] = [.lecture, .history, .importQueue, .dashboard]

    /// Подпись словом: значок без подписи не говорит, куда ведёт.
    var title: String {
        switch self {
        case .lecture: NSLocalizedString("main.section.lecture", comment: "")
        case .history: NSLocalizedString("main.section.history", comment: "")
        case .importQueue: NSLocalizedString("main.section.importQueue", comment: "")
        case .dashboard: NSLocalizedString("main.section.dashboard", comment: "")
        }
    }

    var systemImage: String {
        switch self {
        case .lecture: "text.book.closed"
        case .history: "clock"
        case .importQueue: "arrow.down.doc"
        case .dashboard: "chart.bar"
        }
    }
}

/// Периоды статистики. Прежде — переключатель в шапке, теперь — список
/// раздела статистики.
enum StatisticsPeriod: Int, CaseIterable, Identifiable, Hashable {
    case day = 1
    case week = 7
    case month = 30

    var id: Int { rawValue }
    var dayCount: Int { rawValue }
    var title: String { self == .day ? "Сегодня" : "\(rawValue) дней" }
}
