import SwiftUI

/// Блок «Звук для оценки» в разделе истории: переключатель, сколько
/// сохранено и удаление всего сразу.
struct EvaluationAudioSection: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var model: EvaluationAudioControlsModel
    @State private var showingDeleteConfirmation = false

    init(appState: AppState, settings: AppSettings) {
        self.settings = settings
        _model = StateObject(wrappedValue: EvaluationAudioControlsModel(
            summary: { await appState.evaluationAudioSummary() },
            deleteAll: { try await appState.deleteEvaluationAudio() }
        ))
    }

    var body: some View {
        Section {
            Toggle("settings.evaluationAudio.toggle", isOn: $settings.saveAudioForEvaluation)
            Text("settings.evaluationAudio.explanation")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("settings.evaluationAudio.toggle") {
                Text(model.summaryText)
                    .foregroundStyle(.secondary)
            }
            .labelsHidden()
            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Text("settings.evaluationAudio.delete")
            }
            .disabled(!model.canDelete)
            if let failure = model.failureMessage {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .confirmationDialog(
            "settings.evaluationAudio.deleteConfirmTitle",
            isPresented: $showingDeleteConfirmation
        ) {
            Button("settings.evaluationAudio.deleteConfirmAction", role: .destructive) {
                Task { await model.deleteAll() }
            }
        }
        .task { await model.refresh() }
    }
}
