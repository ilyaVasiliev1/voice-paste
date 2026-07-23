import Foundation

/// Downloads the WhisperKit model (and its tokenizer) from direct GitHub
/// Release asset URLs and lays them down on disk, as an alternative to
/// WhisperKit's HuggingFace-Hub download path (`L-010`, `AT-093`).
///
/// Why this exists: from mainland China `huggingface.co` and the `hf-mirror.com`
/// mirror are unreachable/throttled, so the one-time 626 MB fetch fails or
/// restarts endlessly. GitHub is reachable there. The model is an open,
/// static artifact (Whisper, OpenAI) hosted on the project's own release, so a
/// plain HTTPS download of a `.zip` bypasses the Hub entirely.
///
/// Robustness is the whole point of this type (`L-010`, "качественно
/// обрабатывается и не засоряется"):
/// - `URLSessionDownloadTask` streams straight to a temp file (no in-memory
///   buffering of ~450 MB);
/// - a failed attempt is retried with bounded exponential backoff, **resuming**
///   from the bytes already on disk via `URLSession` resume data (falling back
///   to a clean restart when the server can't resume);
/// - request/resource timeouts bound a stalled connection;
/// - cancellation is cooperative and produces resume data so a later attempt
///   continues instead of restarting;
/// - every exit path (success, failure, cancel) cleans its temp files, so a
///   broken download never leaves junk behind.
public actor GitHubModelDownloader {

    /// One archive to fetch and unpack. `expectedChild` is a path, relative to
    /// `destination`, that must exist after extraction — the download is only
    /// considered successful once it does, so a truncated/partial archive can
    /// never be mistaken for a complete model.
    public struct Archive: Sendable {
        public let url: URL
        public let destination: URL
        public let expectedChild: String
        /// Weight of this archive in the combined progress (`0...1`). The model
        /// dwarfs the tokenizer, so the tokenizer barely moves the bar.
        public let progressWeight: Double

        public init(url: URL, destination: URL, expectedChild: String, progressWeight: Double) {
            self.url = url
            self.destination = destination
            self.expectedChild = expectedChild
            self.progressWeight = progressWeight
        }
    }

    public enum DownloadError: Error, Equatable, Sendable {
        case cancelled
        case httpStatus(Int)
        case extractionFailed
        case verificationFailed
    }

    private static let maxAttemptsPerArchive = 5
    /// A single request that produces no bytes for this long is treated as a
    /// stall and retried; the resource ceiling bounds the whole transfer.
    private static let requestTimeout: TimeInterval = 45
    private static let resourceTimeout: TimeInterval = 2 * 60 * 60

    private let workDirectory: URL
    private var isCancelled = false
    private var activeTask: URLSessionDownloadTask?
    private var activeDelegate: DownloadDelegate?

    /// - Parameter workDirectory: a scratch directory this downloader fully
    ///   owns; partial `.zip` files live here and are removed on completion.
    public init(workDirectory: URL) {
        self.workDirectory = workDirectory
    }

    /// Fetches every archive in order and reports combined progress in `0...1`,
    /// weighted by each archive's `progressWeight`. Throws on unrecoverable
    /// failure or cancellation; always leaves the work directory clean.
    public func fetchAll(
        _ archives: [Archive],
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { cleanWorkDirectory() }

        var completedWeight = 0.0
        for archive in archives {
            try checkCancelled()
            // Capture per-iteration constants: a `@Sendable` progress closure
            // must not capture the mutable running total (Swift 6).
            let base = completedWeight
            let weight = archive.progressWeight
            try await fetch(archive) { fraction in
                progress(min(base + fraction * weight, 0.999))
            }
            completedWeight += weight
        }
        progress(1.0)
    }

    /// Cancels any in-flight download. The active task is cancelled *producing
    /// resume data* so a subsequent attempt continues from where it stopped
    /// rather than from zero.
    public func cancel() {
        isCancelled = true
        activeDelegate?.markCancelled()
        activeTask?.cancel()
    }

    // MARK: - Single archive

    private func fetch(
        _ archive: Archive,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        var resumeData: Data?
        var lastError: Error = DownloadError.httpStatus(-1)

        for attempt in 0..<Self.maxAttemptsPerArchive {
            try checkCancelled()
            do {
                let downloaded = try await runDownload(
                    url: archive.url,
                    resumeData: resumeData,
                    progress: progress
                )
                try await extract(zip: downloaded, into: archive.destination)
                try? FileManager.default.removeItem(at: downloaded)
                try verify(archive)
                return
            } catch let error as DownloadError where error == .cancelled {
                throw error
            } catch {
                lastError = error
                // Keep resume data if the failure produced any, so the next
                // attempt continues instead of restarting the whole transfer.
                resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                guard attempt < Self.maxAttemptsPerArchive - 1 else { break }
                let backoffSeconds = min(pow(2.0, Double(attempt + 1)), 20)
                try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
            }
        }
        throw lastError
    }

    /// One download attempt via `URLSessionDownloadTask`, bridged to async.
    /// Returns the temp file URL of the completed download (still inside the
    /// session's temp area — the caller moves/extracts it immediately).
    private func runDownload(
        url: URL,
        resumeData: Data?,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        try checkCancelled()

        let delegate = DownloadDelegate(progress: progress)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.resourceTimeout
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            delegate.completion = { result in
                switch result {
                case .success(let tempURL):
                    // Move out of the delegate's temp location synchronously
                    // inside the callback (the file is deleted when this
                    // callback returns), into our own owned work directory.
                    let dest = self.workDirectoryPathSync(for: url)
                    try? FileManager.default.removeItem(at: dest)
                    do {
                        try FileManager.default.moveItem(at: tempURL, to: dest)
                        continuation.resume(returning: dest)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            let task: URLSessionDownloadTask
            if let resumeData {
                task = session.downloadTask(withResumeData: resumeData)
            } else {
                task = session.downloadTask(with: url)
            }
            storeActive(task: task, delegate: delegate)
            task.resume()
        }
    }

    // `nonisolated` helper so it can be called synchronously from inside the
    // delegate completion callback (which runs off this actor). It only builds
    // a URL from immutable inputs.
    private nonisolated func workDirectoryPathSync(for url: URL) -> URL {
        workDirectory.appendingPathComponent(url.lastPathComponent + ".partial")
    }

    private func storeActive(task: URLSessionDownloadTask, delegate: DownloadDelegate) {
        activeTask = task
        activeDelegate = delegate
    }

    // MARK: - Extraction / verification / cleanup

    /// Unzips via `/usr/bin/ditto`, which ships on every macOS and handles the
    /// standard zip written by `zip -X` correctly (including nested `.mlmodelc`
    /// bundles). The app is not sandboxed, so spawning it is permitted.
    private func extract(zip: URL, into destination: URL) async throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, destination.path]
        // Nothing in ditto's output is user-facing. Piping without draining
        // can fill the pipe and deadlock a verbose child; /dev/null keeps the
        // extraction bounded and lets completion be driven solely by status.
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { completed in
                    continuation.resume(returning: completed.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            // Process is thread-safe for termination. Cancelling a model
            // download must not leave a CPU/disk-heavy unzip running after
            // the owning task has gone away.
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        guard status == 0 else {
            throw DownloadError.extractionFailed
        }
    }

    private func verify(_ archive: Archive) throws {
        let child = archive.destination.appendingPathComponent(archive.expectedChild)
        guard FileManager.default.fileExists(atPath: child.path) else {
            throw DownloadError.verificationFailed
        }
    }

    private func checkCancelled() throws {
        if isCancelled || Task.isCancelled { throw DownloadError.cancelled }
    }

    private func cleanWorkDirectory() {
        try? FileManager.default.removeItem(at: workDirectory)
    }
}

/// `URLSessionDownloadDelegate` bridging byte-progress and completion to the
/// actor. Kept separate (an `NSObject`) because `URLSession` requires an
/// `NSObjectProtocol` delegate; it holds no app state beyond the two closures.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    enum Result { case success(URL); case failure(Error) }

    private let progress: @Sendable (Double) -> Void
    var completion: ((Result) -> Void)?
    private let lock = NSLock()
    private var cancelled = false

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func markCancelled() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 1.0))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Validate the HTTP status here — a 4xx/5xx still "finishes" with an
        // error-body file that must not be mistaken for the archive.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            completion?(.failure(GitHubModelDownloader.DownloadError.httpStatus(http.statusCode)))
            return
        }
        completion?(.success(location))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return } // success already reported above
        lock.lock(); let wasCancelled = cancelled; lock.unlock()
        if wasCancelled {
            completion?(.failure(GitHubModelDownloader.DownloadError.cancelled))
        } else {
            completion?(.failure(error))
        }
    }
}
