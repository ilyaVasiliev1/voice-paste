import Foundation
import Testing

@testable import VoicePaste

/// Замер, а не охрана: сколько знаков препинания модель ставит на реальной
/// речи окнами по 28 с. Запускается вручную — нужны приватная
/// запись, установленная модель и файл-метка `run-punctuation-measure` в
/// `~/Library/Caches/VoicePaste`. Числа печатаются строкой `MEASURE`.
@Suite("Замер: знаки препинания на реальной речи")
struct PunctuationMeasurement {

    private static let fixture = TestFixtureLocator.url(
        for: "TelegramOGG/sample-01.ogg",
        sourceFile: #filePath
    )

    private static let modelDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VoicePaste/Models", isDirectory: true)

    private static var requested: Bool {
        let marker = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoicePaste/run-punctuation-measure")
        return FileManager.default.fileExists(atPath: marker.path)
    }

    private static func counts(_ text: String) -> (words: Int, marks: Int) {
        let marks = text.filter { ",.!?;:…".contains($0) }.count
        return (text.split(whereSeparator: \.isWhitespace).count, marks)
    }

    @Test(
        "знаков на 100 слов на записи 132 с",
        .enabled(if: PunctuationMeasurement.fixture != nil && PunctuationMeasurement.requested,
                 "нет записи или метки замера")
    )
    func marksPerHundredWords() async throws {
        let url = try #require(Self.fixture)
        let samples = try await AudioDecoder().decode(url: url)
        let engine = try await ModelManager.defaultTranscriberFactory(
            modelDirectory: Self.modelDirectory,
            endpoint: ModelCatalog.downloadEndpoint,
            downloadProgress: { _ in }
        )

        let window = 28 * 16_000
        var text = ""
        var windows = 0
        var empty = 0
        var start = 0
        let began = Date()
        while start < samples.count {
            let end = min(start + window, samples.count)
            windows += 1
            do {
                let result = try await engine.transcribe(TranscriptionRequest(
                    samples: Array(samples[start..<end]),
                    language: .ru
                ))
                text += " " + result.rawText
            } catch TranscribingError.emptyAudio {
                empty += 1
            }
            start = end
        }
        let (words, marks) = Self.counts(text)
        let per100 = words == 0 ? 0 : Double(marks) * 100 / Double(words)
        let seconds = Int(Date().timeIntervalSince(began))
        print("MEASURE windows=\(windows) empty=\(empty) words=\(words) marks=\(marks) per100=\(String(format: "%.1f", per100)) seconds=\(seconds)")
    }
}
