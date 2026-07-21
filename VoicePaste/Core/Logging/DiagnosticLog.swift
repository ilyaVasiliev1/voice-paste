import Foundation

/// Local, size-rotated diagnostic log (`L-012`, `_standards.md`
/// observability, `data-model.md` → `Application Support/VoicePaste/Logs/`).
/// By construction this type only ever receives short event names/reasons —
/// callers must never pass audio bytes or transcription text here.
public actor DiagnosticLog {
    public static let shared = DiagnosticLog()

    private let maxFileBytes: Int
    private let logFileURL: URL?

    private init(maxFileBytes: Int = 1_000_000) {
        self.maxFileBytes = maxFileBytes
        self.logFileURL = try? Self.makeLogFileURL()
    }

    public func log(_ event: String, detail: String = "") {
        guard let logFileURL else { return }
        rotateIfNeeded(url: logFileURL)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) \(event) \(detail)\n"
        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: logFileURL.path), let handle = try? FileHandle(forWritingTo: logFileURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: logFileURL)
        }
    }

    private func rotateIfNeeded(url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int,
              size > maxFileBytes else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    private static func makeLogFileURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("VoicePaste/Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("voicepaste.log")
    }
}
