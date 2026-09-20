import XCTest

@testable import VoicePaste

/// Замер скорости распознавания на настоящей модели и настоящей записи.
///
/// Нужен, чтобы решить, имеет ли смысл считать окна параллельно записи. Ответ
/// зависит от одного числа — доли реального времени, которую съедает
/// распознавание. Если минута речи считается девять секунд, параллельный счёт
/// срежет почти всё ожидание после остановки; если полсекунды, экономить
/// нечего, и работу делать не надо.
///
/// **В обычный прогон не входит.** Поднимает модель на 626 МБ и греет машину,
/// поэтому запускается только осознанно:
///
///     touch ~/Library/Caches/VoicePaste/run-benchmark
///     zsh scripts/test-safely.sh \
///       -only-testing:VoicePasteTests/TranscriptionSpeedBenchmark
///     rm ~/Library/Caches/VoicePaste/run-benchmark
///
/// Ворота — файл, а не переменная среды, потому что переменные приходят
/// тестовому хосту только из схемы: ни `VOICEPASTE_BENCHMARK=1` перед
/// командой, ни `TEST_RUNNER_…` до него не доезжают (проверено). Файл лежит
/// вне репозитория и им можно управлять из командной строки.
///
/// Модель берётся установленная, из каталога приложения, а не тестовая:
/// мерить надо то, что работает у пользователя.
@MainActor
final class TranscriptionSpeedBenchmark: XCTestCase {

    private static let sampleRate = 16_000

    /// Длины отрезков, на которых меряем. 5 с — типичная короткая диктовка,
    /// 28 с — окно, которым режет импорт, дальше — лекционный масштаб.
    private static let sliceDurations: [Int] = [5, 15, 28, 60, 120]

    func test_measureRealtimeFactorAcrossRecordingLengths() async throws {
        let marker = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoicePaste/run-benchmark")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: marker.path),
            "Замер скорости не входит в обычный прогон: см. заголовок файла."
        )

        let samples = try await decodeFixture()
        let available = Double(samples.count) / Double(Self.sampleRate)
        XCTAssertGreaterThan(available, 120, "Запись короче самого длинного отрезка")

        let transcriber = try await makeTranscriberOnInstalledModel()

        // Первый прогон оплачивает компиляцию и прогрев и в таблицу не идёт —
        // иначе он исказит самый короткий отрезок, по которому решение и
        // принимается.
        let warmUp = Array(samples.prefix(Self.sampleRate * 3))
        let warmUpSeconds = try await measure(transcriber, samples: warmUp)

        var rows: [(seconds: Int, elapsed: Double, factor: Double)] = []
        for seconds in Self.sliceDurations {
            let slice = Array(samples.prefix(Self.sampleRate * seconds))
            let elapsed = try await measure(transcriber, samples: slice)
            rows.append((seconds, elapsed, elapsed / Double(seconds)))
        }

        report(warmUpSeconds: warmUpSeconds, rows: rows)
    }

    // MARK: - Механика

    private func measure(_ transcriber: any Transcribing, samples: [Float]) async throws -> Double {
        let started = Date()
        _ = try await transcriber.transcribe(
            TranscriptionRequest(samples: samples, language: .auto)
        )
        return Date().timeIntervalSince(started)
    }

    private func decodeFixture() async throws -> [Float] {
        let url = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("VoicePasteTests/Fixtures/TelegramOGG/sample-01.ogg")
        let direct = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/TelegramOGG/sample-01.ogg")
        let existing = FileManager.default.fileExists(atPath: direct.path) ? direct : url
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: existing.path),
            "Фикстура sample-01.ogg не найдена — она приватная и в git не входит."
        )
        return try await AudioDecoder().decode(url: existing)
    }

    private func makeTranscriberOnInstalledModel() async throws -> any Transcribing {
        let installed = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoicePaste/Models", isDirectory: true)
        try XCTSkipUnless(
            LocalModelDetection.discoverModelFolder(in: installed) != nil,
            "Модель не установлена — замер невозможен, устанавливать её тест не станет."
        )
        return try await ModelManager.defaultTranscriberFactory(
            modelDirectory: installed,
            endpoint: ModelCatalog.downloadEndpoint,
            downloadProgress: { _ in }
        )
    }

    private func report(warmUpSeconds: Double, rows: [(seconds: Int, elapsed: Double, factor: Double)]) {
        var lines = [
            "",
            "ЗАМЕР СКОРОСТИ РАСПОЗНАВАНИЯ",
            String(format: "Прогрев (3 с речи): %.2f с — в таблицу не входит", warmUpSeconds),
            "",
            "  речь, с | счёт, с | доля реального времени",
            "  --------|---------|-----------------------",
        ]
        for row in rows {
            lines.append(String(format: "  %7d | %7.2f | %.3f", row.seconds, row.elapsed, row.factor))
        }
        if let longest = rows.last {
            let saved = longest.elapsed - (longest.elapsed / Double(longest.seconds)) * 28
            lines.append("")
            lines.append(String(
                format: "На записи в %d с параллельный счёт окнами по 28 с срезал бы ожидание "
                    + "после остановки примерно с %.1f с до %.1f с.",
                longest.seconds, longest.elapsed, max(0, longest.elapsed - saved)
            ))
        }
        print(lines.joined(separator: "\n"))
    }
}
