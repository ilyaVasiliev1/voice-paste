import Charts
import SwiftUI

/// Статистика за окно дней: что прочитано и в каком оно состоянии.
///
/// «Пусто» показывается только после первой выборки: до неё `stats` — заглушка,
/// а не честный ноль, и «Здесь появится статистика» мигало до прихода данных.
@MainActor
final class UsageStatsModel: ObservableObject {
    @Published private(set) var stats = UsageStats.empty
    @Published private(set) var isLoaded = false
    /// Статистику не удалось прочитать. Поднято, чтобы отказ не
    /// выдавался за отсутствие данных.
    @Published private(set) var didFailToLoad = false

    private let store: any HistoryStoring

    init(store: any HistoryStoring) {
        self.store = store
    }

    /// Первый сигнал потока приходит сразу при подписке и даёт первую загрузку.
    func track(dayCount: Int) async {
        for await _ in store.changes() {
            await load(dayCount: dayCount)
        }
    }

    private func load(dayCount: Int) async {
        do {
            stats = try await store.fetchUsageStats(now: Date(), dayCount: dayCount)
            isLoaded = true
            didFailToLoad = false
        } catch {
            // Прежде отказ базы подменялся пустой статистикой и становился
            // неотличим от честного «вы ещё ничего не наговорили».
            didFailToLoad = true
            await DiagnosticLog.shared.log("dashboard.statsFailed", detail: String(describing: error))
        }
    }
}

/// Local overview with factual daily points, not a generic dashboard.
struct DashboardView: View {
    /// Период выбирается в списке раздела статистики.
    let period: StatisticsPeriod

    /// Не наблюдается: нужен для перехода в очередь, а перерисовку от
    /// лекции и модели вид получать не должен.
    private let appState: AppState
    @ObservedObject private var importManager: ImportManager
    @StateObject private var model: UsageStatsModel
    @State private var selectedDay: DailyUsageStat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(period: StatisticsPeriod, appState: AppState) {
        self.period = period
        self.appState = appState
        _importManager = ObservedObject(wrappedValue: appState.importManager)
        _model = StateObject(wrappedValue: UsageStatsModel(store: appState.historyStore))
    }

    private var stats: UsageStats { model.stats }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
                header
                if importManager.activeQueueCount > 0 { queueStatus }
                metrics
                    .redacted(reason: model.isLoaded || model.didFailToLoad ? [] : .placeholder)
                chart
            }
            .padding(DesignTokens.detailPanePadding)
        }
        // Смена периода перезапускает слежение, а с ним и загрузку.
        .task(id: period) {
            selectedDay = nil
            await model.track(dayCount: period.dayCount)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(period.title).font(.title2.weight(.semibold))
        }
    }

    private var queueStatus: some View {
        Button { appState.openImportQueue() } label: {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "arrow.down.doc").foregroundStyle(Color.accentColor)
                Text("В очереди: \(importManager.activeQueueCount)")
                if let job = importManager.currentJob {
                    Text("· \(job.displayStage)").foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, DesignTokens.Spacing.md).padding(.vertical, DesignTokens.Spacing.sm)
        }
        .buttonStyle(.plain)
        .cardSurface()
    }

    private var metrics: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            // Отказ чтения — прочерк, а не «0»: ноль выглядел бы как «записей не было».
            let failed = model.didFailToLoad
            metric(failed ? "—" : stats.totalWordCount.formatted(), "Слов")
            metric(failed ? "—" : SpeechDurationText.text(milliseconds: stats.totalDurationMilliseconds), "Время речи")
            metric(failed ? "—" : stats.totalTranscriptCount.formatted(), "Расшифровок")
        }
    }

    private func metric(_ value: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Spacing.lg)
        .cardSurface()
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack {
                Text(period == .day ? "Слов по часам" : "Слов по дням").font(.headline)
                Spacer()
                if let selectedDay { tooltip(for: selectedDay) }
            }
            if !model.isLoaded && !model.didFailToLoad {
                Color.clear.frame(maxWidth: .infinity, minHeight: DesignTokens.chartMinHeight)
            } else if stats.dailyStats.isEmpty || stats.totalTranscriptCount == 0 {
                Group {
                    if model.didFailToLoad {
                        // Отказ базы больше не выдаётся за «записей нет».
                        ContentUnavailableView(
                            "dashboard.statsFailed.title",
                            systemImage: "exclamationmark.triangle",
                            description: Text("dashboard.statsFailed.description")
                        )
                    } else {
                        ContentUnavailableView(
                            "Здесь появится статистика",
                            systemImage: "chart.bar"
                        )
                    }
                }
                .frame(maxWidth: .infinity, minHeight: DesignTokens.chartMinHeight)
            } else {
                // Столбцы, а не линия: при редкой речи линия превращалась в
                // ряд нулей с одним всплеском, а столбец читается и в одиночку.
                Chart(stats.dailyStats, id: \.day) { item in
                    BarMark(
                        x: .value("Период", item.day, unit: period == .day ? .hour : .day),
                        y: .value("Слова", item.wordCount)
                    )
                    .foregroundStyle(Color.accentColor.opacity(selectedDay == nil || selectedDay?.day == item.day ? 1 : 0.45))
                    .cornerRadius(2)
                }
                .animation(
                    DesignTokens.Motion.respecting(DesignTokens.Motion.fade, reduceMotion: reduceMotion),
                    value: selectedDay?.day
                )
                .chartYScale(domain: 0...max(1, stats.dailyStats.map(\.wordCount).max() ?? 1))
                // Подписи по X без вертикальной сетки: двойная сетка читалась как шум.
                .chartXAxis {
                    AxisMarks(values: .stride(by: period == .day ? .hour : .day, count: period == .day ? 3 : period == .month ? 7 : 1)) { _ in
                        AxisValueLabel(anchor: .top)
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine()
                        AxisValueLabel(anchor: .leading)
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                guard case .active(let location) = phase,
                                      let plotFrame = proxy.plotFrame,
                                      let date: Date = proxy.value(atX: location.x - geometry[plotFrame].minX) else {
                                    if case .ended = phase { selectedDay = nil }
                                    return
                                }
                                selectedDay = nearestDay(to: date)
                            }
                    }
                }
                .frame(height: 230)
            }
            Text(period == .day
                ? "Активных часов: \(stats.activeDayCount) из 24"
                : "Активных дней: \(stats.activeDayCount) из \(period.dayCount)")
                .font(.caption).foregroundStyle(.secondary)
                .redacted(reason: model.isLoaded || model.didFailToLoad ? [] : .placeholder)
        }
        .padding(DesignTokens.Spacing.lg)
        .cardSurface()
        // Подсказка графика живёт на наведении — для VoiceOver и клавиатуры её нет, поэтому сводка текстом.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(period == .day ? "Слов по часам" : "Слов по дням"))
        .accessibilityValue(Text(
            DisplayFormat.words(stats.totalWordCount) + ", "
                + DisplayFormat.transcriptions(stats.totalTranscriptCount)
        ))
    }

    private func tooltip(for day: DailyUsageStat) -> some View {
        let pointDate = period == .day
            ? day.day.formatted(date: .omitted, time: .shortened)
            : day.day.formatted(Date.FormatStyle().day().month(.abbreviated))
        return Text(DisplayFormat.dayUsage(
            dateText: pointDate,
            words: day.wordCount,
            transcriptions: day.transcriptCount,
            durationMilliseconds: day.durationMilliseconds
        ))
        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }

    private func nearestDay(to date: Date) -> DailyUsageStat? {
        stats.dailyStats.min { abs($0.day.timeIntervalSince(date)) < abs($1.day.timeIntervalSince(date)) }
    }
}

/// Слов за каждый период — подпись под названием в списке раздела статистики.
@MainActor
final class PeriodSummaries: ObservableObject {
    @Published private(set) var words: [StatisticsPeriod: Int] = [:]

    private let store: any HistoryStoring

    init(store: any HistoryStoring) {
        self.store = store
    }

    func track() async {
        for await _ in store.changes() {
            await load()
        }
    }

    /// Недоступный период остаётся без подписи, а не с нулём: ноль был бы ложью.
    private func load() async {
        for period in StatisticsPeriod.allCases {
            if let stats = try? await store.fetchUsageStats(now: Date(), dayCount: period.dayCount) {
                words[period] = stats.totalWordCount
            }
        }
    }
}

/// Список раздела статистики: периоды с итогом под каждым.
struct StatisticsPeriodList: View {
    @Binding var period: StatisticsPeriod
    @StateObject private var summaries: PeriodSummaries

    init(period: Binding<StatisticsPeriod>, store: any HistoryStoring) {
        _period = period
        _summaries = StateObject(wrappedValue: PeriodSummaries(store: store))
    }

    var body: some View {
        List(StatisticsPeriod.allCases, selection: selection) { item in
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text(item.title)
                if let words = summaries.words[item] {
                    Text("Слов: \(words.formatted())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, DesignTokens.Spacing.xs)
            .tag(item)
        }
        .task { await summaries.track() }
    }

    private var selection: Binding<StatisticsPeriod?> {
        Binding(get: { period }, set: { if let value = $0 { period = value } })
    }
}
