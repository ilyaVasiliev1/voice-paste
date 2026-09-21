import SwiftUI

/// Единственное постоянное окно: разделы слева, список раздела посередине,
/// деталь выбранного справа. Каждый раздел владеет обеими правыми колонками,
/// а его действия стоят в панели инструментов.
struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var history = HistoryListModel()
    @State private var section: MainContentSection = .history
    @State private var period: StatisticsPeriod = .month

    var body: some View {
        NavigationSplitView {
            List(MainContentSection.sidebarOrder, id: \.self, selection: sectionSelection) { item in
                Label(item.title, systemImage: item.systemImage)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(
                min: MainWindowLayout.sidebarMinWidth,
                ideal: MainWindowLayout.sidebarIdealWidth,
                max: MainWindowLayout.sidebarMaxWidth
            )
            .accessibilityLabel(Text("main.sections"))
        } content: {
            listColumn
                .navigationSplitViewColumnWidth(
                    min: MainWindowLayout.listMinWidth,
                    ideal: MainWindowLayout.listIdealWidth,
                    max: MainWindowLayout.listMaxWidth
                )
        } detail: {
            detailColumn
                .frame(minWidth: MainWindowLayout.detailMinWidth)
        }
        .navigationTitle(section.title)
        .frame(
            minWidth: MainWindowLayout.windowMinWidth,
            minHeight: MainWindowLayout.windowMinHeight
        )
        .safeAreaInset(edge: .top, spacing: 0) {
            if appState.persistenceFailureMessage != nil {
                Label(
                    NSLocalizedString("storage.unavailable", comment: ""),
                    systemImage: "externaldrive.badge.exclamationmark"
                )
                .font(.callout)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DesignTokens.Spacing.lg)
                .padding(.vertical, DesignTokens.Spacing.sm)
                .background(.orange.opacity(0.14))
                .overlay(alignment: .bottom) { Divider() }
                .accessibilityIdentifier("storage-unavailable-banner")
            }
        }
        .task { await history.observeChanges() }
        .onAppear {
            // Хранилище подключается здесь, синхронно и до выбора записи:
            // `.task` может стартовать позже `onAppear`, и тогда «Открыть в
            // истории» выбирало запись при ещё пустой модели — деталь
            // оставалась пустой навсегда.
            history.attach(appState.historyStore)
            consumeRequestedSection()
            consumeRequestedHistorySelection()
        }
        .onChange(of: appState.requestedMainContentSection) { _, _ in consumeRequestedSection() }
        .onChange(of: appState.requestedHistorySelection) { _, _ in consumeRequestedHistorySelection() }
    }

    @ViewBuilder
    private var listColumn: some View {
        switch section {
        case .lecture: LectureListColumn()
        case .history: HistoryListColumn(model: history)
        case .importQueue: ImportQueueList()
        case .dashboard: StatisticsPeriodList(period: $period)
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        switch section {
        case .lecture: LectureView(recorder: appState.lectureRecorder, settings: appState.settings)
        case .history: HistoryDetailColumn(model: history)
        case .importQueue: ImportQueueView()
        case .dashboard: DashboardView(period: period)
        }
    }

    private var sectionSelection: Binding<MainContentSection?> {
        Binding(get: { section }, set: { if let value = $0 { section = value } })
    }

    private func consumeRequestedSection() {
        guard let requested = appState.requestedMainContentSection else { return }
        section = requested
        appState.requestedMainContentSection = nil
    }

    /// «Открыть в истории» из плашки: раздел истории с этой записью в списке.
    private func consumeRequestedHistorySelection() {
        guard let requested = appState.requestedHistorySelection else { return }
        section = .history
        history.selection = requested
        appState.requestedHistorySelection = nil
    }
}
