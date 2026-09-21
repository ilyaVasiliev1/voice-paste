import Charts
import SwiftUI

/// Local overview with factual daily points, not a generic dashboard.
struct DashboardView: View {
    private enum Period: Int, CaseIterable, Identifiable {
        case day = 1, week = 7, month = 30
        var id: Int { rawValue }
        var title: String { self == .day ? "Сегодня" : "\(rawValue) дней" }
    }

    @EnvironmentObject private var appState: AppState
    @State private var stats = UsageStats.empty
    /// Статистику не удалось прочитать. Поднято, чтобы отказ не
    /// выдавался за отсутствие данных.
    @State private var didFailToLoad = false
    @State private var period: Period = .month
    @State private var selectedDay: DailyUsageStat?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if appState.importManager.activeQueueCount > 0 { queueStatus }
                metrics
                chart
            }
            .padding(DesignTokens.detailPanePadding)
        }
        .task {
            await load()
            await observeChanges()
        }
        .onChange(of: period) { _, _ in Task { await load() } }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Статистика").font(.title2.weight(.semibold))
                Text("Локально на этом Mac").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Период", selection: $period) {
                ForEach(Period.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).frame(width: 260)
        }
    }

    private var queueStatus: some View {
        Button { appState.openImportQueue() } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.doc").foregroundStyle(Color.accentColor)
                Text("В очереди: \(appState.importManager.activeQueueCount)")
                if let job = appState.importManager.currentJob {
                    Text("· \(job.displayStage)").foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius, style: .continuous))
    }

    private var metrics: some View {
        HStack(spacing: 10) {
            metric(stats.totalWordCount.formatted(), "Слов")
            metric(SpeechDurationText.text(milliseconds: stats.totalDurationMilliseconds), "Время речи")
            metric(stats.totalTranscriptCount.formatted(), "Расшифровок")
        }
    }

    private func metric(_ value: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius, style: .continuous))
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                : "Активных дней: \(stats.activeDayCount) из \(period.rawValue)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius, style: .continuous))
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
                dayCount: period.rawValue
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
