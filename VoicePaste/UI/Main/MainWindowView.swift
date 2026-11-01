import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var history: HistoryListModel
    @State private var section: MainContentSection = .history
    @State private var period: StatisticsPeriod = .month

    init(historyStore: any HistoryStoring) {
        _history = StateObject(wrappedValue: HistoryListModel(store: historyStore))
    }

    var body: some View {
        GeometryReader { geometry in
        HStack(spacing: 0) {
            sidebar
                .frame(width: MainWindowLayout.sidebarIdealWidth)
                .background(WorkspacePalette.sidebar)
                .overlay(alignment: .trailing) { WorkspacePalette.line.frame(width: 1) }
            VStack(spacing: 0) {
                HStack {
                    Text(section.title).font(.system(size: 14, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .frame(height: 56)
                .overlay(alignment: .bottom) { WorkspacePalette.line.frame(height: 1) }
                listColumn.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: min(MainWindowLayout.listIdealWidth,
                max(MainWindowLayout.listMinWidth, geometry.size.width
                    - MainWindowLayout.sidebarIdealWidth - MainWindowLayout.detailMinWidth)))
            .background(WorkspacePalette.list)
            .overlay(alignment: .trailing) { WorkspacePalette.line.frame(width: 1) }
            detailColumn
                .frame(minWidth: MainWindowLayout.detailMinWidth)
        }
        .background(WorkspacePalette.document)
        }
        .frame(minWidth: MainWindowLayout.windowMinWidth, minHeight: MainWindowLayout.windowMinHeight)
        .task { await history.observeChanges() }
        .onAppear {
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
        case .history: HistoryListColumn(model: history, appState: appState)
        case .importQueue: ImportQueueList()
        case .dashboard: StatisticsPeriodList(period: $period, store: appState.historyStore)
        }
    }

    /// Плашки состояния над деталью: готовность и хранилище. Внутри правой колонки, а не окна:
    /// над всем окном они ложились поверх боковой колонки и списка.
    @ViewBuilder
    private var statusBanners: some View {
            if appState.readiness.state != .ready {
                HStack(spacing: DesignTokens.Spacing.md) {
                    Label(
                        NSLocalizedString(appState.readiness.state.statusLocalizationKey, comment: ""),
                        systemImage: "exclamationmark.triangle"
                    )
                    Spacer()
                    Button("main.readiness.configure") {
                        WindowRouter.shared.open("onboarding")
                    }
                }
                .font(.callout)
                .padding(.horizontal, DesignTokens.Spacing.lg)
                .padding(.vertical, DesignTokens.Spacing.sm)
                .background(.orange.opacity(0.14))
                .overlay(alignment: .bottom) { Divider() }
                .accessibilityIdentifier("readiness-banner")
            }
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

    private var detailColumn: some View {
        VStack(spacing: 0) {
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            statusBanners
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(WorkspacePalette.document)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch section {
        case .lecture: LectureView(recorder: appState.lectureRecorder, settings: appState.settings)
        case .history: HistoryDetailColumn(model: history)
        case .importQueue: ImportQueueView()
        case .dashboard: DashboardView(period: period, appState: appState)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .semibold))
                Text("VoicePaste").font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(height: 56)
            VStack(spacing: 4) {
                ForEach(MainContentSection.sidebarOrder, id: \.self) { item in
                    Button { section = item } label: {
                        Label(item.title, systemImage: item.systemImage)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(WorkspaceRowStyle(selected: section == item))
                    .accessibilityAddTraits(section == item ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Circle().fill(appState.readiness.state == .ready ? Color.green : Color.orange).frame(width: 6, height: 6)
                    Text(appState.readiness.state == .ready ? "Локальная обработка" : "Требуется настройка")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Text("VoicePaste \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Button { WindowRouter.shared.openSettings() } label: {
                    Label("main.settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(WorkspaceRowStyle())
            }
            .padding(10)
        }
        .accessibilityLabel(Text("main.sections"))
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
