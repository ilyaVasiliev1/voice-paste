import Foundation

/// Склеивает результаты окон одной записи в один текст.
///
/// Язык берётся из первого окна, у которого он определён, и держится: при
/// определении на каждом окне порознь язык скакал бы внутри одной записи.
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
