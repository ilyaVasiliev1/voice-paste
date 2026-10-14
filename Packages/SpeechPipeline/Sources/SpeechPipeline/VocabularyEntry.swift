import Foundation

/// Plain domain model for a personal-dictionary rule. Mirrors `DM-004` exactly.
nonisolated public struct VocabularyEntry: Codable, Identifiable, Equatable, Sendable {
    /// Primary key.
    public var id: UUID
    /// Spoken phrase, matched case-insensitively.
    public var spokenForm: String
    /// Explicit local replacement; `nil`/empty means "never autocorrect this word".
    public var replacement: String?
    public var isEnabled: Bool
    public var createdAt: Int64
    public var updatedAt: Int64

    public init(
        id: UUID,
        spokenForm: String,
        replacement: String?,
        isEnabled: Bool = true,
        createdAt: Int64,
        updatedAt: Int64
    ) {
        self.id = id
        self.spokenForm = spokenForm
        self.replacement = replacement
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
