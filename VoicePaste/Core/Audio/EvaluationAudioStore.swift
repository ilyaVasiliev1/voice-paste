import Foundation

nonisolated public struct EvaluationAudioSummary: Equatable, Sendable {
    public let fileCount: Int
    public let totalBytes: Int

    public init(fileCount: Int, totalBytes: Int) {
        self.fileCount = fileCount
        self.totalBytes = totalBytes
    }
}

/// Куда уходит звук, сохранённый для оценки качества распознавания.
nonisolated public protocol EvaluationAudioStoring: Sendable {
    func save(samples: [Float], id: UUID) async throws
    func delete(id: UUID) async throws
    func summary() async -> EvaluationAudioSummary
    func deleteAll() async throws -> Int
}

/// Записи для оценки: каталог 0700, файлы 0600, вне резервных копий, имя — только UUID записи.
public actor EvaluationAudioStore: EvaluationAudioStoring {
    private let directory: URL
    private static let sampleRate: UInt32 = 16_000

    public init(directory: URL) {
        self.directory = directory
    }

    /// Под тестовым прогоном — временный каталог: пользовательских данных не трогаем.
    public static func makeDefault() -> EvaluationAudioStore {
        if ProcessRuntime.isRunningTests {
            return EvaluationAudioStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("VoicePasteTests-EvaluationAudio", isDirectory: true)
            )
        }
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return EvaluationAudioStore(
            directory: base.appendingPathComponent("VoicePaste/EvaluationAudio", isDirectory: true)
        )
    }

    public func save(samples: [Float], id: UUID) throws {
        try prepareDirectory()
        let url = directory.appendingPathComponent("\(id.uuidString).wav")
        try Self.waveData(from: samples).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func summary() -> EvaluationAudioSummary {
        let files = recordings()
        let bytes = files.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return EvaluationAudioSummary(fileCount: files.count, totalBytes: bytes)
    }

    public func delete(id: UUID) throws {
        let prefix = id.uuidString
        for url in recordings() where url.lastPathComponent.hasPrefix(prefix) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func deleteAll() throws -> Int {
        var removed = 0
        for url in recordings() {
            try FileManager.default.removeItem(at: url)
            removed += 1
        }
        return removed
    }

    // MARK: - Механика

    private func recordings() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        // Имя начинается с UUID записи: сюда же попадает недописанный временный файл.
        return contents.filter { UUID(uuidString: String($0.lastPathComponent.prefix(36))) != nil }
    }

    private func prepareDirectory() throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = directory
        try mutable.setResourceValues(values)
    }

    /// WAV PCM 16 кГц моно 16 бит; выход за ±1 насыщается.
    private static func waveData(from samples: [Float]) -> Data {
        let dataSize = UInt32(samples.count * 2)
        var data = Data(capacity: 44 + Int(dataSize))
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        data.append(contentsOf: Array("RIFF".utf8))
        append32(36 + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)
        append16(1)                       // PCM
        append16(1)                       // моно
        append32(sampleRate)
        append32(sampleRate * 2)          // байт в секунду
        append16(2)                       // выравнивание блока
        append16(16)                      // разрядность
        data.append(contentsOf: Array("data".utf8))
        append32(dataSize)
        for sample in samples {
            let scaled = (max(-1, min(1, sample)) * 32_768).rounded()
            let clamped = Int16(max(-32_768, min(32_767, scaled)))
            append16(UInt16(bitPattern: clamped))
        }
        return data
    }
}
