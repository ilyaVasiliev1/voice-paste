import Foundation

/// Склейка окон записи; язык берётся из первого окна, где он определён.
nonisolated public struct TranscriptAccumulator: Sendable {
    private var text = ""
    private var detectedLanguage: String?

    public init() {}

    public mutating func append(_ window: TranscriptionResult) {
        text = TranscriptChunkMerger.merge(text, with: window.rawText)
        if detectedLanguage == nil { detectedLanguage = window.detectedLanguage }
    }

    public var result: TranscriptionResult {
        TranscriptionResult(rawText: text, detectedLanguage: detectedLanguage)
    }

    public mutating func reset() {
        self = TranscriptAccumulator()
    }
}
