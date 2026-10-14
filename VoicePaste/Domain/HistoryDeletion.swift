import Foundation

/// Что убрали из истории: одну запись или всё сразу.
nonisolated public enum HistoryDeletion: Sendable, Equatable {
    case record(UUID)
    case all
}
