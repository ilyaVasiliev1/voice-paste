import SwiftUI

/// One permanent macOS window. History and statistics share its split view.
/// Statistics is opened from the menu bar; the toolbar remains only for
/// actions on the content currently visible.
struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState
    @State private var section: MainContentSection = .history

    var body: some View {
        HistoryView(section: $section)
            .frame(minWidth: 680, minHeight: 460)
            .safeAreaInset(edge: .top, spacing: 0) {
                if appState.persistenceFailureMessage != nil {
                    Label(
                        NSLocalizedString("storage.unavailable", comment: ""),
                        systemImage: "externaldrive.badge.exclamationmark"
                    )
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.orange.opacity(0.14))
                    .overlay(alignment: .bottom) { Divider() }
                    .accessibilityIdentifier("storage-unavailable-banner")
                }
            }
            .onAppear { consumeRequestedSection() }
            .onChange(of: appState.requestedMainContentSection) { _, _ in consumeRequestedSection() }
    }

    private func consumeRequestedSection() {
        guard let requested = appState.requestedMainContentSection else { return }
        section = requested
        appState.requestedMainContentSection = nil
    }

}
