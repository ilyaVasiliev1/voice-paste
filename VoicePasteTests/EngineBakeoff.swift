import Foundation
import Testing

@testable import VoicePaste

/// Стенд сравнения моделей: не охрана, а замер. Нужны набор клипов
/// (`scripts/make-bakeoff-set.sh`) и метка `run-bakeoff` в `~/Library/Caches/VoicePaste`.
/// Результат печатается строками `BAKEOFF`; недостающие модели скачиваются в
/// `~/Library/Caches/VoicePaste/Bakeoff/models`, установленную копию стенд не меняет.
@Suite("Стенд сравнения моделей")
struct EngineBakeoff {

    private struct Clip: Decodable {
        let id: String
        let language: String
        let text: String
    }

    private static let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VoicePaste", isDirectory: true)
    private static let clipsDirectory = caches.appendingPathComponent("Bakeoff/clips", isDirectory: true)
    private static let installedModels = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VoicePaste/Models", isDirectory: true)

    private static let variants = (ProcessInfo.processInfo.environment["BAKEOFF_VARIANTS"]
        ?? "large-v3-v20240930_626MB,large-v3-v20240930_turbo_632MB,large-v3_947MB")
        .split(separator: ",").map(String.init)

    private static var requested: Bool {
        FileManager.default.fileExists(atPath: caches.appendingPathComponent("run-bakeoff").path)
    }

    private static func marks(in text: String) -> Int {
        text.filter { ",.!?;:…，。！？".contains($0) }.count
    }

    @Test(
        "числа по моделям на наборе клипов",
        .enabled(if: EngineBakeoff.requested, "нет метки run-bakeoff"),
        .timeLimit(.minutes(60))
    )
    func compareVariants() async throws {
        let manifestURL = Self.clipsDirectory.appendingPathComponent("manifest.json")
        let clips = try JSONDecoder().decode([Clip].self, from: Data(contentsOf: manifestURL))

        for variant in Self.variants {
            let directory = variant == ModelCatalog.modelID
                ? Self.installedModels
                : Self.caches.appendingPathComponent("Bakeoff/models/\(variant)", isDirectory: true)
            let loadStart = Date()
            let engine = try await WhisperKitTranscriber(
                modelDirectory: directory,
                endpoint: ModelCatalog.downloadEndpoint,
                tokenizerFolder: ModelManager.tokenizerDirectory(in: Self.installedModels),
                variant: variant
            )
            let loadSeconds = Date().timeIntervalSince(loadStart)

            var errors: [String: [Double]] = [:]
            var marksTotal = 0
            var wordsTotal = 0
            var audioSeconds = 0.0
            var inferenceSeconds = 0.0
            var silenceCharacters = 0
            for clip in clips {
                let samples = try await AudioDecoder().decode(url: Self.clipsDirectory.appendingPathComponent("\(clip.id).wav"))
                let started = Date()
                let text: String
                do {
                    text = try await engine.transcribe(TranscriptionRequest(
                        samples: samples,
                        language: TranscriptionLanguage(rawValue: clip.language) ?? .ru
                    )).rawText
                } catch TranscribingError.emptyAudio {
                    text = ""
                }
                let elapsed = Date().timeIntervalSince(started)
                if clip.language == "none" {
                    silenceCharacters += text.trimmingCharacters(in: .whitespacesAndNewlines).count
                    continue
                }
                audioSeconds += Double(samples.count) / 16_000
                inferenceSeconds += elapsed
                let rate = clip.language == "zh"
                    ? ErrorRate.characters(reference: clip.text, hypothesis: text)
                    : ErrorRate.words(reference: clip.text, hypothesis: text)
                errors[clip.language, default: []].append(rate)
                if clip.language == "ru" {
                    marksTotal += Self.marks(in: text)
                    wordsTotal += text.split(whereSeparator: \.isWhitespace).count
                }
            }
            func mean(_ language: String) -> String {
                guard let values = errors[language], !values.isEmpty else { return "-" }
                return String(format: "%.3f", values.reduce(0, +) / Double(values.count))
            }
            let marks100 = wordsTotal == 0 ? 0 : Double(marksTotal) * 100 / Double(wordsTotal)
            print("BAKEOFF variant=\(variant) werRu=\(mean("ru")) cerZh=\(mean("zh")) werEn=\(mean("en")) "
                + "silenceChars=\(silenceCharacters) marksPer100Ru=\(String(format: "%.1f", marks100)) "
                + "rtf=\(String(format: "%.3f", inferenceSeconds / max(audioSeconds, 1))) "
                + "loadSec=\(String(format: "%.1f", loadSeconds))")
        }
    }
}
