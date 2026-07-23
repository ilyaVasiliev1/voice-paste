import Foundation

/// Language selector forwarded to the transcriber (`DM-001.languageMode`).
nonisolated public enum TranscriptionLanguage: String, Codable, CaseIterable, Sendable {
    case auto
    case ru
    case en
}

/// One transcription request: 16 kHz mono Float32 samples (the format both
/// the microphone capture pipeline and the DEP-008 import decoder produce).
nonisolated public struct TranscriptionRequest: Sendable {
    public var samples: [Float]
    public var sampleRate: Double
    public var language: TranscriptionLanguage
    /// Optional progress sink for long inputs (`EC-013`, imported files).
    public var onProgress: (@Sendable (Double) -> Void)?

    public init(
        samples: [Float],
        sampleRate: Double = 16_000,
        language: TranscriptionLanguage,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.language = language
        self.onProgress = onProgress
    }
}

/// Recognition output: capitalization/punctuation come from the model
/// itself (`L-005`), before any normalization step runs.
nonisolated public struct TranscriptionResult: Sendable, Equatable {
    public var rawText: String
    public var detectedLanguage: String?

    public init(rawText: String, detectedLanguage: String?) {
        self.rawText = rawText
        self.detectedLanguage = detectedLanguage
    }
}

nonisolated public enum TranscribingError: Error, Equatable, Sendable {
    case modelNotReady
    case emptyAudio
    case cancelled
    case underlying(String)
}

/// Joins sequential Whisper windows while removing the textual overlap
/// shared by adjacent windows. It never rewrites words; it only drops an
/// exact normalized suffix/prefix match of at least two tokens.
nonisolated public enum TranscriptChunkMerger {
    public static func merge(_ current: String, with next: String) -> String {
        let left = tokens(current)
        let right = tokens(next)
        guard !left.isEmpty else { return next.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !right.isEmpty else { return current.trimmingCharacters(in: .whitespacesAndNewlines) }

        let maximum = min(24, left.count, right.count)
        var overlap = 0
        if maximum >= 2 {
            for count in stride(from: maximum, through: 2, by: -1) {
                let leftSlice = left.suffix(count).map(normalizedToken)
                let rightSlice = right.prefix(count).map(normalizedToken)
                if leftSlice == rightSlice, !leftSlice.contains("") {
                    overlap = count
                    break
                }
            }
        }

        let remainder = right.dropFirst(overlap).joined(separator: " ")
        if remainder.isEmpty { return left.joined(separator: " ") }
        return left.joined(separator: " ") + " " + remainder
    }

    private static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func normalizedToken(_ token: String) -> String {
        token.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// Abstraction over the local speech-to-text engine so the app compiles and
/// is unit-testable regardless of whether the concrete WhisperKit adapter is
/// available in a given build environment. The WhisperKit-backed
/// implementation lives in `WhisperKitTranscriber.swift`, isolated behind
/// `#if canImport(WhisperKit)`.
/// Inference is intentionally nonisolated: a local Whisper run may occupy
/// CPU/Metal for a long time, but it must never inherit the SwiftUI main
/// actor simply because the caller is an observable application object.
nonisolated public protocol Transcribing: Sendable {
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult
}

/// Deterministic stand-in used by SwiftUI previews and unit tests
/// (`_tests.md`: transcriber must be mockable so DB/UI tests never invoke
/// WhisperKit or touch the microphone).
nonisolated public struct MockTranscriber: Transcribing {
    public var result: Result<TranscriptionResult, TranscribingError>

    public init(result: Result<TranscriptionResult, TranscribingError> = .success(.init(rawText: "", detectedLanguage: nil))) {
        self.result = result
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        try result.get()
    }
}
