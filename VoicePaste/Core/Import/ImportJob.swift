import Foundation

/// Persisted description of a local media import. The source itself lives
/// only in the matching cache directory while the job is active.
nonisolated public struct ImportJob: Identifiable, Equatable, Sendable {
    public enum State: String, Codable, CaseIterable, Sendable {
        case staging
        case queued
        case preparing
        case transcribing
        case paused
        case failed

        public var isActive: Bool {
            switch self {
            case .staging, .queued, .preparing, .transcribing, .paused: true
            case .failed: false
            }
        }
    }

    public enum MediaKind: String, Codable, Sendable {
        case audio
        case video
    }

    public let id: UUID
    public let fileName: String
    public let createdAt: Int64
    public var mediaKind: MediaKind
    public var durationMilliseconds: Int?
    public var state: State
    public var progress: Double
    public var stageStartedAt: Int64
    public var failureKey: String?

    public init(
        id: UUID = UUID(),
        fileName: String,
        createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        mediaKind: MediaKind,
        durationMilliseconds: Int? = nil,
        state: State = .staging,
        progress: Double = 0,
        stageStartedAt: Int64? = nil,
        failureKey: String? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.createdAt = createdAt
        self.mediaKind = mediaKind
        self.durationMilliseconds = durationMilliseconds
        self.state = state
        self.progress = min(max(progress, 0), 1)
        self.stageStartedAt = stageStartedAt ?? createdAt
        self.failureKey = failureKey
    }

    public var displayStage: String {
        switch state {
        case .staging: return "Копирование файла"
        case .queued: return "В очереди"
        case .preparing: return "Подготовка аудио"
        case .transcribing: return "Расшифровка"
        case .paused: return "Приостановлено"
        case .failed: return "Не удалось обработать"
        }
    }
}
