import AVFoundation
import Foundation

public enum AudioCaptureError: Error, Equatable, Sendable {
    case microphoneUnavailable
    case engineFailed(String)
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
    private var sumOfSquares: Double = 0
    private var sampleCount = 0
    private(set) var lastLevel: Float = 0

    func append(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        var peak: Float = 0
        var chunkSumOfSquares: Double = 0
        for value in chunk {
            peak = max(peak, abs(value))
            chunkSumOfSquares += Double(value * value)
        }
        lock.lock()
        samples.append(contentsOf: chunk)
        sumOfSquares += chunkSumOfSquares
        sampleCount += chunk.count
        lastLevel = peak
        lock.unlock()
    }

    func drain() -> [Float] {
        drainWithRMS().samples
    }

    func drainWithRMS() -> (samples: [Float], rms: Float) {
        lock.lock()
        defer {
            samples.removeAll()
            sumOfSquares = 0
            sampleCount = 0
            lock.unlock()
        }
        let rms = sampleCount == 0 ? 0 : Float((sumOfSquares / Double(sampleCount)).squareRoot())
        return (samples, rms)
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
    }
}

/// Captures microphone audio only for the duration of an active dictation
/// session (`DEP-003`, `L-004`). Output is always resampled to 16 kHz mono
/// Float32 — the format `Transcribing` implementations expect, matching the
/// DEP-008 import decode path.
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
    private var levelPollTask: Task<Void, Never>?

    public init() {}

    public func start() throws {
        try beginCapture(clearingExistingSamples: true)
    }

    /// Resumes a dictation after its temporary Escape pause. The audio engine
    /// itself is intentionally fresh, but the accumulator is preserved so
    /// both spoken segments become one transcription.
    public func resume() throws {
        try beginCapture(clearingExistingSamples: false)
    }

    private func beginCapture(clearingExistingSamples: Bool) throws {
        guard !isCapturing else { return }
        if clearingExistingSamples {
            _ = accumulator.drain()
            lastCaptureRMS = 0
        }

        // Belt-and-suspenders (`EC-004`): `ReadinessCoordinator` already
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
        startLevelPolling()
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
        guard isCapturing, let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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
