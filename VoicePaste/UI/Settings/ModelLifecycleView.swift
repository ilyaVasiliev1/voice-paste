import SwiftUI

/// Состояние модели одним видом — для настроек и для шага модели в
/// онбординге.
///
/// Прежде было написано дважды и разошлось: настройки показывали загрузку
/// одной строкой статуса, без прогресса и без отмены, а онбординг — прогресс,
/// скорость и остаток времени. Теперь оба экрана показывают одно и то же.
struct ModelLifecycleView: View {
    @EnvironmentObject private var appState: AppState
    /// Онбордингу выбор источника нужен рядом с кнопкой загрузки; в
    /// настройках он стоит отдельной строкой и виден всегда.
    var showsSourcePicker = true

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch appState.modelManager.state {
        case .ready, .unloaded:
            Label("model.status.ready", systemImage: "checkmark.circle.fill")
        case .preparing:
            // Модель с диска поднимается в память — не загрузка.
            HStack(spacing: DesignTokens.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("model.status.preparing")
            }
        case .downloading(let progress):
            downloading(progress)
        case .verifying:
            HStack(spacing: DesignTokens.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("model.status.verifying")
            }
        case .failed:
            Text("model.status.failed").foregroundStyle(.red)
            if showsSourcePicker { ModelSourcePicker(settings: appState.settings) }
            Button("onboarding.model.retry") { install() }
        case .notPrepared:
            Text("model.status.notPrepared").foregroundStyle(.secondary)
            if showsSourcePicker { ModelSourcePicker(settings: appState.settings) }
            Button("onboarding.model.download") { install() }
        }
    }

    private func install() {
        Task { _ = try? await appState.modelManager.installModel() }
    }

    /// `AT-086`/`L-010`/`UI-002`: honest download progress — percent and
    /// "N из 626 МБ" read straight from `ModelDownloadProgress`'s byte
    /// counters, plus current speed and an ETA that only appears once the
    /// smoothed speed is a trustworthy signal (until then, "Считаем
    /// время…", mirroring `AT-062`'s import progress wording).
    private func downloading(_ progress: ModelDownloadProgress) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            ProgressView(value: progress.fraction)
            HStack {
                Text(Self.byteCountFormatter.string(fromByteCount: progress.completedBytes)
                     + " " + String(format: NSLocalizedString("onboarding.model.ofTotal", comment: ""),
                                     Self.byteCountFormatter.string(fromByteCount: progress.totalBytes)))
                Spacer()
                Text(Self.percentFormatter.string(from: NSNumber(value: progress.fraction)) ?? "")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(Self.speedAndETAText(progress))
                .font(.caption)
                .foregroundStyle(.secondary)
            // `L-010`: cancel the in-flight download and clear whatever was
            // written, dropping back to `.notPrepared` so the source can be
            // switched and the download restarted from the chosen host.
            Button("onboarding.model.cancelDownload") {
                appState.modelManager.cancelDownload()
                Task { await appState.modelManager.deleteModel() }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    private static func speedAndETAText(_ progress: ModelDownloadProgress) -> String {
        guard let speed = progress.speedBytesPerSecond, speed > 0 else {
            return NSLocalizedString("onboarding.model.calculatingTime", comment: "")
        }
        let speedText = String(
            format: NSLocalizedString("onboarding.model.speed", comment: ""),
            byteCountFormatter.string(fromByteCount: Int64(speed))
        )
        guard let eta = progress.etaSeconds, eta.isFinite, eta >= 0 else {
            return speedText
        }
        let etaText = String(
            format: NSLocalizedString("onboarding.model.eta", comment: ""),
            durationText(eta)
        )
        return speedText + " · " + etaText
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let value = Int(seconds.rounded())
        return value >= 60 ? "\(value / 60) мин" : "\(value) с"
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter
    }()

    private static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter
    }()
}

/// Источник загрузки модели — одна настройка `settings.modelDownloadSource`
/// (`AT-093`, `AT-096`, `L-010`) и один выбор на оба экрана.
///
/// Пояснение одно на оба экрана. Прежде онбординг советовал из Китая
/// китайское зеркало, а настройки — GitHub как единственный рабочий оттуда
/// источник; верно второе.
struct ModelSourcePicker: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Picker("settings.model.downloadSource", selection: $settings.modelDownloadSource) {
                Text("settings.model.downloadSource.github").tag(ModelDownloadSource.github)
                Text("settings.model.downloadSource.mirror").tag(ModelDownloadSource.mirror)
                Text("settings.model.downloadSource.official").tag(ModelDownloadSource.official)
            }
            Text("settings.model.downloadSource.explanation")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
