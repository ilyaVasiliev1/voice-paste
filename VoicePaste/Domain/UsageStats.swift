import Foundation

/// A lightweight day bucket for local statistics. It never carries transcript
/// text, so opening Statistics does not load history bodies into memory.
public nonisolated struct DailyUsageStat: Equatable, Sendable {
    public let day: Date
    public let wordCount: Int
    public let transcriptCount: Int
    public let durationMilliseconds: Int

    public init(day: Date, wordCount: Int, transcriptCount: Int, durationMilliseconds: Int = 0) {
        self.day = day
        self.wordCount = wordCount
        self.transcriptCount = transcriptCount
        self.durationMilliseconds = durationMilliseconds
    }
}

/// Summary for the rolling 30-day local statistics window.
public nonisolated struct UsageStats: Equatable, Sendable {
    public let dailyStats: [DailyUsageStat]
    public let totalWordCount: Int
    public let totalTranscriptCount: Int
    public let totalDurationMilliseconds: Int
    public let activeDayCount: Int

    public init(
        dailyStats: [DailyUsageStat],
        totalWordCount: Int,
        totalTranscriptCount: Int,
        totalDurationMilliseconds: Int,
        activeDayCount: Int
    ) {
        self.dailyStats = dailyStats
        self.totalWordCount = totalWordCount
        self.totalTranscriptCount = totalTranscriptCount
        self.totalDurationMilliseconds = totalDurationMilliseconds
        self.activeDayCount = activeDayCount
    }

    public static let empty = UsageStats(
        dailyStats: [], totalWordCount: 0, totalTranscriptCount: 0,
        totalDurationMilliseconds: 0, activeDayCount: 0
    )
}
