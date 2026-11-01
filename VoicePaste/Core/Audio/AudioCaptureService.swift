import AVFoundation
import Foundation

public enum AudioCaptureError: Error, Equatable, Sendable {
    case microphoneUnavailable
    case engineFailed(String)
}

/// Что случилось с захватом, пока шла запись: система сменила или убрала устройство ввода.
nonisolated public enum AudioCaptureInterruption: Equatable, Sendable {
    case restarted
    case failed(String)
}

/// Thread-safe sink for samples produced on the real-time audio thread
/// (`AVAudioEngine` taps never run on the main actor).
///
/// Declared `nonisolated`: under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// every declaration in the module — including plain (non-actor) classes —
/// defaults to `@MainActor` isolation unless stated otherwise. Without this
/// modifier, this whole type (and its stored properties/methods) would be
/// `@MainActor`-isolated despite being `Sendable`, and calling into it from
/// the real-time audio thread would trip exactly the
/// `_dispatch_assert_queue_fail` this type exists to avoid.
nonisolated final class AudioSampleAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var spool: LectureAudioSpool?
    private var sumOfSquares: Double = 0
    private var sampleCount = 0
    private var level: Float = 0
    var lastLevel: Float {
        lock.lock(); defer { lock.unlock() }
        return level
    }
    /// Куда отдавать каждый пришедший кусок 16 кГц моно. Ставится на время
    /// записи лекции потоковым движком.
    private var chunkHandler: (@Sendable ([Float]) -> Void)?
    var onChunk: (@Sendable ([Float]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return chunkHandler }
        set { lock.lock(); defer { lock.unlock() }; chunkHandler = newValue }
    }

    func append(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        var peak: Float = 0
        var chunkSumOfSquares: Double = 0
        for value in chunk {
            peak = max(peak, abs(value))
            chunkSumOfSquares += Double(value * value)
        }
        lock.lock()
        if let spool { spool.append(chunk) } else { samples.append(contentsOf: chunk) }
        sumOfSquares += chunkSumOfSquares
        sampleCount += chunk.count
        level = peak
        lock.unlock()
    }

    /// Сколько сэмплов накоплено на сейчас. Нужно нарезке окон, которая
    /// считает закрывшиеся отрезки, пока запись ещё идёт.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return sampleCount
    }

    /// Чтение не потребляет данные: перекрывающиеся окна обращаются к одному звуку.
    /// Диапазон ограничен записанным, чтобы гонка с аудиопотоком не выходила за границы.
    func snapshot(_ range: Range<Int>) -> [Float] {
        lock.lock()
        if let spool {
            lock.unlock()
            return spool.snapshot(range)
        }
        let clamped = range.clamped(to: 0..<samples.count)
        let result = clamped.isEmpty ? [] : Array(samples[clamped])
        lock.unlock()
        return result
    }

    var residentSampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count
    }

    var storageFailure: String? {
        lock.lock(); defer { lock.unlock() }
        return spool?.failure
    }

    func useDiskStorage() throws {
        let next = try LectureAudioSpool()
        lock.lock()
        let previous = spool
        samples.removeAll()
        spool = next
        sampleCount = 0
        sumOfSquares = 0
        lock.unlock()
        withExtendedLifetime(previous) {}
    }

    func clear() {
        lock.lock()
        let previous = spool
        samples.removeAll()
        spool = nil
        sampleCount = 0
        sumOfSquares = 0
        level = 0
        lock.unlock()
        withExtendedLifetime(previous) {}
    }

    func drain() -> [Float] {
        drainWithRMS().samples
    }

    func drainWithRMS() -> (samples: [Float], rms: Float) {
        lock.lock()
        let source = spool
        let buffered = samples
        let count = sampleCount
        let rms = count == 0 ? 0 : Float((sumOfSquares / Double(count)).squareRoot())
        samples.removeAll()
        spool = nil
        sumOfSquares = 0
        sampleCount = 0
        lock.unlock()
        return (source?.snapshot(0..<count) ?? buffered, rms)
    }

}

// A bounded queue avoids retaining hours of PCM; overflow is reported rather than dropping old audio.
nonisolated final class LectureAudioSpool: @unchecked Sendable {
    private let queue = DispatchQueue(label: "VoicePaste.lecture-audio-spool")
    private let stateLock = NSLock()
    private let url: URL
    private let handle: FileHandle
    private var pendingBytes = 0
    private var issue: String?
    private var writtenSamples = 0
    private let limit: Int

    init(maxPendingBytes: Int = 8 * 1_024 * 1_024) throws {
        limit = maxPendingBytes
        url = FileManager.default.temporaryDirectory.appendingPathComponent("VoicePaste-lecture-\(UUID().uuidString).pcm")
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
            attributes: [.posixPermissions: 0o600]) else {
            throw AudioCaptureError.engineFailed("Cannot create lecture audio buffer")
        }
        handle = try FileHandle(forUpdating: url)
    }

    deinit {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    var failure: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return issue
    }

    func append(_ samples: [Float]) {
        let bytes = samples.count * MemoryLayout<Float>.stride
        stateLock.lock()
        guard issue == nil, pendingBytes + bytes <= limit else {
            if issue == nil { issue = "Lecture audio buffer overloaded; transcription may be incomplete" }
            stateLock.unlock()
            return
        }
        pendingBytes += bytes
        stateLock.unlock()
        queue.async { [self] in
            defer {
                stateLock.lock(); pendingBytes -= bytes; stateLock.unlock()
            }
            do {
                try handle.seekToEnd()
                try samples.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
                writtenSamples += samples.count
            } catch {
                stateLock.lock(); issue = "Lecture audio could not be stored"; stateLock.unlock()
            }
        }
    }

    func snapshot(_ range: Range<Int>) -> [Float] {
        queue.sync {
            let clipped = range.clamped(to: 0..<writtenSamples)
            guard !clipped.isEmpty else { return [] }
            do {
                try handle.seek(toOffset: UInt64(clipped.lowerBound * MemoryLayout<Float>.stride))
                let data = try handle.read(upToCount: clipped.count * MemoryLayout<Float>.stride) ?? Data()
                return data.withUnsafeBytes { raw in
                    (0..<(raw.count / MemoryLayout<Float>.stride)).map {
                        raw.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.stride, as: Float.self)
                    }
                }
            } catch {
                stateLock.lock(); issue = "Lecture audio could not be read"; stateLock.unlock()
                return []
            }
        }
    }
}

/// Converts raw input buffers to the 16 kHz mono Float32 target format and
/// forwards the samples to the accumulator. This type is deliberately
/// `nonisolated`/`Sendable` and holds no reference to the `@MainActor`
/// `AudioCaptureService`: `AVAudioEngine` invokes the tap block — and the
/// tap block invokes `AVAudioConverter.convert(to:error:withInputFrom:)`,
/// which in turn invokes the *input block* below — on a dedicated real-time
/// audio thread, never on the main thread. Because module builds in this
/// project default to `@MainActor` isolation
/// (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), any closure defined
/// directly inside a `@MainActor` type would silently inherit that
/// isolation; the Swift 6 runtime then asserts the executor at the call
/// site, which fails on the audio thread and crashes with
/// `_dispatch_assert_queue_fail` / `-10877`. Defining the conversion — and
/// therefore the input block — inside this `nonisolated` type keeps both
/// closures free of actor isolation. Declared `nonisolated` for the same
/// reason as `AudioSampleAccumulator` above: under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` a plain class would
/// otherwise default to `@MainActor` isolation for all its members.
nonisolated final class AudioTapProcessor: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private let inputSampleRate: Double
    private let accumulator: AudioSampleAccumulator

    init(
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        inputSampleRate: Double,
        accumulator: AudioSampleAccumulator
    ) {
        self.converter = converter
        self.targetFormat = targetFormat
        self.inputSampleRate = inputSampleRate
        self.accumulator = accumulator
    }

    /// Called on the real-time audio thread by the tap block. Not isolated
    /// to any actor: converts `buffer` to the target format and appends the
    /// resulting samples to the (thread-safe) accumulator.
    func process(_ buffer: AVAudioPCMBuffer) {
        let capacity = AVAudioFrameCount(
            Double(buffer.frameLength) * 16_000.0 / inputSampleRate
        ) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return
        }
        // `AVAudioConverter.convert(to:error:withInputFrom:)`'s input block
        // is checked against `Sendable` by the compiler (it may be invoked
        // reentrantly), which rejects capturing `buffer`
        // (`AVAudioPCMBuffer` is not `Sendable`) and a mutable `var` across
        // that boundary. Both are safe here: `convert` calls the input
        // block synchronously, on this same (audio) thread, at most once
        // per `consumed` check below — there is no actual concurrent
        // access. `nonisolated(unsafe)` documents that safety without
        // resorting to a lock for a single-threaded, single-call handoff.
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let bufferToConsume = buffer
        var conversionError: NSError?
        converter.convert(to: outBuffer, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return bufferToConsume
        }
        guard conversionError == nil, let channelData = outBuffer.floatChannelData else { return }
        let frameCount = Int(outBuffer.frameLength)
        let chunk = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        accumulator.append(chunk)
        // Диктовка может подписываться на куски; лекция читает ограниченные диапазоны из файла.
        accumulator.onChunk?(chunk)
    }
}

/// Captures microphone audio only for the duration of an active dictation
/// session. Output is always resampled to 16 kHz mono
/// Float32 — the format `Transcribing` implementations expect, matching the
/// import decode path.
@MainActor
public final class AudioCaptureService {
    public private(set) var isCapturing = false
    /// RMS of the most recently stopped capture. It is accumulated on the
    /// audio thread, so deciding whether a buffer is silent never requires a
    /// second O(n) scan of a long recording on the main actor.
    public private(set) var lastCaptureRMS: Float = 0

    // A brand-new `AVAudioEngine` is created for every session (`start()`)
    // and released on `stop()`/failure. Reusing one long-lived engine across
    // sessions — even with `removeTap`/`stop`/`reset` — was observed to leave
    // stale I/O-thread/audio-unit state behind after certain sessions
    // (in particular a previously *failed* session), which then surfaces as
    // `EXC_BREAKPOINT` in `_dispatch_assert_queue_fail` on the AudioSession
    // root queue and `-10877` (`kAudioUnitErr_InvalidElement`) the next time a
    // tap is installed/started. A fresh instance per session guarantees a
    // clean audio graph and avoids that class of crash entirely (`L-004`,
    // `EC-004`).
    private var engine: AVAudioEngine?
    private let accumulator = AudioSampleAccumulator()
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    /// Fires roughly on every audio buffer with the current peak amplitude
    /// (0...1) for the HUD level indicator. Always called on the main actor.
    public var onLevel: ((Float) -> Void)?

    /// Каждый пришедший кусок звука: 16 кГц, моно, Float32. Зовётся с
    /// аудиопотока, не с главного актора. Пусто — никто не слушает.
    public var onAudioChunk: (@Sendable ([Float]) -> Void)? {
        get { accumulator.onChunk }
        set { accumulator.onChunk = newValue }
    }

    public var onInterruption: ((AudioCaptureInterruption) -> Void)?
    private var configurationObserver: NSObjectProtocol?
    /// Растёт при явном start/resume/pause/stop: начатый до них перезапуск обязан уступить.
    private var restartToken = 0
    private var levelPollTask: Task<Void, Never>?

    public init() {}

    /// Накоплено сэмплов на сейчас. Читается во время записи нарезкой окон.
    public var capturedSampleCount: Int { accumulator.count }

    /// Копия отрезка накопленного звука, не трогающая буфер. Отдаёт меньше
    /// запрошенного, если столько ещё не записано.
    public func capturedSamples(in range: Range<Int>) -> [Float] {
        accumulator.snapshot(range)
    }

    public var captureStorageFailure: String? { accumulator.storageFailure }

    public func startLecture() throws {
        guard !isCapturing else { return }
        try accumulator.useDiskStorage()
        restartToken += 1
        try beginCapture(clearingExistingSamples: false)
    }

    public func stopPreservingSamples() -> Int {
        pause()
        return accumulator.count
    }

    public func resetCapturedSamples() { accumulator.clear() }

    public func start() throws {
        restartToken += 1
        try beginCapture(clearingExistingSamples: true)
    }

    /// Resumes a dictation after its temporary Escape pause. The audio engine
    /// itself is intentionally fresh, but the accumulator is preserved so
    /// both spoken segments become one transcription.
    public func resume() throws {
        restartToken += 1
        try beginCapture(clearingExistingSamples: false)
    }

    private func beginCapture(clearingExistingSamples: Bool) throws {
        guard !isCapturing else { return }
        if clearingExistingSamples {
            accumulator.clear()
            lastCaptureRMS = 0
        }

        // Belt-and-suspenders: `ReadinessCoordinator` already
        // gates the record command on permission, but re-check here so a
        // revoked/never-granted permission fails cleanly with
        // `.microphoneUnavailable` instead of reaching `AVAudioEngine` and
        // surfacing as an opaque `-10877`.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AudioCaptureError.microphoneUnavailable
        }

        // A fresh engine per session (see the `engine` doc comment above):
        // no reuse, no leftover tap/state from a prior — possibly failed —
        // session can exist on this instance.
        let engine = AVAudioEngine()

        // Accessing `inputNode` (re-)configures the engine's audio graph;
        // do this before `prepare()`/`start()`.
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.microphoneUnavailable
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioCaptureError.engineFailed("Unsupported input format for resampling.")
        }
        let processor = AudioTapProcessor(
            converter: converter,
            targetFormat: targetFormat,
            inputSampleRate: inputFormat.sampleRate,
            accumulator: accumulator
        )

        // Explicitly `@Sendable`-typed tap block. `AVAudioNodeTapBlock`
        // itself is a plain (non-`@Sendable`-annotated) block typealias in
        // the AVFAudio headers, so under
        // `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` a closure literal
        // assigned to it — without an explicit `@Sendable` annotation —
        // would still infer `@MainActor` isolation from its enclosing
        // (`@MainActor`) context. Spelling out `@Sendable` on the literal's
        // type overrides that default and forces `nonisolated`, matching
        // where AVAudioEngine actually invokes it. The block only forwards
        // to the `nonisolated` processor above and touches no
        // `@MainActor` state.
        let tapBlock: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            processor.process(buffer)
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat, block: tapBlock)

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Idempotent cleanup on failure: tear the tap down and drop the
            // engine so a subsequent `start()` builds a wholly new graph —
            // never a second tap layered on this one.
            input.removeTap(onBus: 0)
            throw AudioCaptureError.engineFailed(error.localizedDescription)
        }
        self.engine = engine
        isCapturing = true
        observeConfigurationChanges(of: engine)
        startLevelPolling()
    }

    // WHY: смена устройства останавливает движок без ошибки; запись выглядела идущей, а на выходе была тишина.
    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self, weak engine] _ in
            guard let engine else { return }
            let identity = ObjectIdentifier(engine)
            Task { @MainActor in self?.handleConfigurationChange(of: identity) }
        }
    }

    /// Уведомления приходят пачкой: отвечаем только на пришедшее от текущего движка.
    func handleConfigurationChange(of identity: ObjectIdentifier) {
        guard isCapturing, let engine, ObjectIdentifier(engine) == identity else { return }
        tearDownEngine()
        let token = restartToken
        Task { [weak self] in
            guard let self else { return }
            let outcome = await CaptureRestartPolicy.run(
                restart: {
                    guard self.restartToken == token else { throw CancellationError() }
                    try self.beginCapture(clearingExistingSamples: false)
                },
                sleep: { try? await Task.sleep(for: $0) }
            )
            guard self.restartToken == token else { return }
            self.onInterruption?(outcome)
        }
    }

    /// Stops capture and returns the accumulated 16 kHz mono samples.
    /// Caller applies `EC-005` (empty/too-short) and `EC-004` (device dropped
    /// mid-recording, still return whatever valid buffer exists).
    @discardableResult
    public func stop() -> [Float] {
        pause()
        let capture = accumulator.drainWithRMS()
        lastCaptureRMS = capture.rms
        return capture.samples
    }

    /// Stops only microphone capture while retaining converted samples.
    /// Used exclusively for the reversible Escape pause; a later `resume()`
    /// attaches a fresh audio engine to the same accumulator.
    public func pause() {
        restartToken += 1
        tearDownEngine()
    }

    private func tearDownEngine() {
        guard isCapturing, let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        self.engine = nil
        isCapturing = false
        levelPollTask?.cancel()
        levelPollTask = nil
    }

    private func startLevelPolling() {
        levelPollTask?.cancel()
        let accumulator = accumulator
        levelPollTask = Task { [weak self] in
            while let self, self.isCapturing, !Task.isCancelled {
                self.onLevel?(accumulator.lastLevel)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
}
