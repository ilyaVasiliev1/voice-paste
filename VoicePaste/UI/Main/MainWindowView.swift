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
            .onAppear { consumeRequestedSection() }
            .onChange(of: appState.requestedMainContentSection) { _, _ in consumeRequestedSection() }
    }

    private func consumeRequestedSection() {
        guard let requested = appState.requestedMainContentSection else { return }
        section = requested
        appState.requestedMainContentSection = nil
    }

}
