import Charts
import SwiftUI

/// Local overview with factual daily points, not a generic dashboard.
struct DashboardView: View {
    /// Период выбирается в списке раздела статистики.
    let period: StatisticsPeriod

    @EnvironmentObject private var appState: AppState
    @State private var stats = UsageStats.empty
    /// Статистику не удалось прочитать. Поднято, чтобы отказ не
    /// выдавался за отсутствие данных.
    @State private var didFailToLoad = false
    @State private var selectedDay: DailyUsageStat?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
                header
                if appState.importManager.activeQueueCount > 0 { queueStatus }
                metrics
                chart
            }
            .padding(DesignTokens.detailPanePadding)
        }
        // Смена периода перезапускает и загрузку, и слежение за изменениями.
        .task(id: period) {
            selectedDay = nil
            await load()
            await observeChanges()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(period.title).font(.title2.weight(.semibold))
            Text("Локально на этом Mac").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var queueStatus: some View {
        Button { appState.openImportQueue() } label: {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "arrow.down.doc").foregroundStyle(Color.accentColor)
                Text("В очереди: \(appState.importManager.activeQueueCount)")
                if let job = appState.importManager.currentJob {
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
            metric(stats.totalWordCount.formatted(), "Слов")
            metric(SpeechDurationText.text(milliseconds: stats.totalDurationMilliseconds), "Время речи")
            metric(stats.totalTranscriptCount.formatted(), "Расшифровок")
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
                Text(period == .day ? "Речь по часам" : "Речь по дням").font(.headline)
                Spacer()
                if let selectedDay { tooltip(for: selectedDay) }
            }
            if stats.dailyStats.isEmpty || stats.totalTranscriptCount == 0 {
                Group {
                    if didFailToLoad {
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
                .frame(maxWidth: .infinity, minHeight: 210)
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
                .chartYScale(domain: 0...max(1, stats.dailyStats.map(\.wordCount).max() ?? 1))
                .chartXAxis {
                    AxisMarks(values: .stride(by: period == .day ? .hour : .day, count: period == .day ? 3 : period == .month ? 7 : 1))
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                guard case .active(let location) = phase,
                                      let date: Date = proxy.value(atX: location.x) else {
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
        }
        .padding(DesignTokens.Spacing.lg)
        .cardSurface()
    }

    private func tooltip(for day: DailyUsageStat) -> some View {
        let pointDate = period == .day
            ? day.day.formatted(date: .omitted, time: .shortened)
            : day.day.formatted(date: .abbreviated, time: .omitted)
        return Text("\(pointDate) · \(day.wordCount) слов · \(day.transcriptCount) расш. · \(SpeechDurationText.text(milliseconds: day.durationMilliseconds))")
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }

    private func nearestDay(to date: Date) -> DailyUsageStat? {
        stats.dailyStats.min { abs($0.day.timeIntervalSince(date)) < abs($1.day.timeIntervalSince(date)) }
    }

    private func observeChanges() async {
        for await _ in appState.historyStore.changes() { await load() }
    }

    private func load() async {
        do {
            stats = try await appState.historyStore.fetchUsageStats(
                now: Date(),
                dayCount: period.dayCount
            )
            didFailToLoad = false
        } catch {
            // Прежде отказ базы подменялся пустой статистикой и становился
            // неотличим от честного «вы ещё ничего не наговорили». Это тот же
            // класс дефекта, что исправлен в `DetailEditor`: молчаливый отказ
            // выглядит успехом.
            didFailToLoad = true
            await DiagnosticLog.shared.log(
                "dashboard.statsFailed",
                detail: String(describing: error)
            )
        }
    }
}

/// Список раздела статистики: периоды. Прежде — переключатель в шапке.
struct StatisticsPeriodList: View {
    @Binding var period: StatisticsPeriod

    var body: some View {
        List(StatisticsPeriod.allCases, selection: selection) { item in
            Text(item.title).tag(item)
        }
    }

    private var selection: Binding<StatisticsPeriod?> {
        Binding(get: { period }, set: { if let value = $0 { period = value } })
    }
}
