import Foundation
import Testing

@testable import VoicePaste

/// Звук для оценки: выключен по умолчанию, лежит только на этой машине,
/// удаляется одной кнопкой. Звук — персональные данные, поэтому права и
/// границы проверяются так же строго, как содержимое файла.
@Suite("Звук для оценки — хранилище", .serialized)
struct EvaluationAudioStoreTests {

    private func makeStore() throws -> (store: EvaluationAudioStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EvalAudio-\(UUID().uuidString)", isDirectory: true)
        return (EvaluationAudioStore(directory: directory), directory)
    }

    private static func tone(_ count: Int) -> [Float] {
        (0..<count).map { 0.5 * sin(Float($0) * 0.05) }
    }

    @Test("запись — корректный WAV 16 кГц моно 16 бит, отсчёты сохранены")
    func savedFileIsAValidWave() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let samples = Self.tone(16_000)
        let id = UUID()

        try await store.save(samples: samples, id: id)

        let data = try Data(contentsOf: directory.appendingPathComponent("\(id.uuidString).wav"))
        #expect(data.count == 44 + samples.count * 2)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        func u16(_ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }
        #expect(u16(20) == 1)        // PCM
        #expect(u16(22) == 1)        // моно
        #expect(u32(24) == 16_000)   // частота
        #expect(u16(34) == 16)       // разрядность
        #expect(u32(40) == samples.count * 2)

        for index in stride(from: 0, to: samples.count, by: 997) {
            let raw = Int16(bitPattern: UInt16(u16(44 + index * 2)))
            #expect(abs(Float(raw) / 32_768 - samples[index]) < 0.001)
        }
    }

    @Test("выход за ±1 насыщается, а не заворачивается")
    func overloadedSamplesSaturate() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()

        try await store.save(samples: [2.0, -2.0, 0], id: id)

        let data = try Data(contentsOf: directory.appendingPathComponent("\(id.uuidString).wav"))
        let first = Int16(bitPattern: UInt16(data[44]) | UInt16(data[45]) << 8)
        let second = Int16(bitPattern: UInt16(data[46]) | UInt16(data[47]) << 8)
        #expect(first == Int16.max)
        #expect(second == Int16.min)
    }

    @Test("файл виден только владельцу: 0600, каталог 0700")
    func permissionsAreOwnerOnly() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()

        try await store.save(samples: Self.tone(1_600), id: id)

        func mode(_ url: URL) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        #expect(try mode(directory) == 0o700)
        #expect(try mode(directory.appendingPathComponent("\(id.uuidString).wav")) == 0o600)
    }

    @Test("сводка считает файлы и размер")
    func summaryCountsFilesAndBytes() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let empty = await store.summary()
        #expect(empty.fileCount == 0 && empty.totalBytes == 0)

        try await store.save(samples: Self.tone(16_000), id: UUID())
        try await store.save(samples: Self.tone(8_000), id: UUID())

        let summary = await store.summary()
        #expect(summary.fileCount == 2)
        #expect(summary.totalBytes == (44 + 32_000) + (44 + 16_000))
    }

    @Test("удаление убирает записи и возвращает их число, чужие файлы остаются")
    func deleteAllRemovesOnlyRecordings() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.save(samples: Self.tone(1_600), id: UUID())
        try await store.save(samples: Self.tone(1_600), id: UUID())
        let foreign = directory.appendingPathComponent("notes.txt")
        try Data("не звук".utf8).write(to: foreign)

        let removed = try await store.deleteAll()

        #expect(removed == 2)
        #expect(await store.summary().fileCount == 0)
        #expect(FileManager.default.fileExists(atPath: foreign.path))
        // каталог остаётся пригодным
        try await store.save(samples: Self.tone(1_600), id: UUID())
        #expect(await store.summary().fileCount == 1)
    }

    @Test("недописанный временный файл записи считается и удаляется")
    func interruptedWriteLeftoverIsCountedAndDeleted() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.save(samples: Self.tone(1_600), id: UUID())
        let leftover = directory.appendingPathComponent("\(UUID().uuidString).wav.sb-1a2b3c-XyZ")
        try Data(repeating: 1, count: 64).write(to: leftover)

        #expect(await store.summary().fileCount == 2)
        #expect(try await store.deleteAll() == 2)
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }

    @Test("каталог исключён из резервных копий")
    func directoryIsExcludedFromBackup() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await store.save(samples: Self.tone(1_600), id: UUID())

        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test("удаление там, где ничего не сохранялось, — ноль и без ошибки")
    func deleteAllOnEmptyIsZero() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try await store.deleteAll() == 0)
    }
}

@MainActor
@Suite("Звук для оценки — настройка")
struct EvaluationAudioSettingTests {

    @Test("по умолчанию выключен")
    func offByDefault() {
        let defaults = UserDefaults(suiteName: "EvalAudio-\(UUID().uuidString)")!
        #expect(AppSettings(defaults: defaults).saveAudioForEvaluation == false)
    }

    @Test("включённое значение переживает перезапуск")
    func persistsAcrossLaunches() {
        let name = "EvalAudio-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        AppSettings(defaults: defaults).saveAudioForEvaluation = true

        #expect(AppSettings(defaults: UserDefaults(suiteName: name)!).saveAudioForEvaluation == true)
    }
}
