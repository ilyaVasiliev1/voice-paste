import Foundation

/// Stable local boundary for the persisted active import queue. It is kept
/// separate from history rows: a terminal import becomes a Transcript, while
/// jobs carry no transcript text and are removed after completion/cancel.
public protocol ImportQueueStoring: Sendable {
    func restoreJobs() async throws -> [ImportJob]
    func upsert(_ job: ImportJob) async throws
    func delete(id: UUID) async throws
}

/// Fallback used only when `history.sqlite` could not be opened. It keeps a
/// short-lived queue usable but intentionally cannot promise crash recovery.
public actor InMemoryImportQueueStore: ImportQueueStoring {
    private var jobs: [UUID: ImportJob] = [:]

    public init() {}

    public func restoreJobs() async throws -> [ImportJob] {
        for id in jobs.keys {
            guard var job = jobs[id] else { continue }
            if job.state.isActive {
                job.state = .queued
                job.progress = 0
                jobs[id] = job
            }
        }
        return jobs.values.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    public func upsert(_ job: ImportJob) async throws { jobs[job.id] = job }
    public func delete(id: UUID) async throws { jobs.removeValue(forKey: id) }
}
