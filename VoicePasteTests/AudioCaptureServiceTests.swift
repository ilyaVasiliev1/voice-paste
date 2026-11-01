import AVFoundation
import XCTest
@testable import VoicePaste

/// `AudioCaptureService` wraps a real `AVAudioEngine`/microphone input node
/// directly (no `Transcribing`-style protocol to substitute), so its actual
/// capture path needs a live microphone
/// and stays a manual test per the gate's scope. This only covers the
/// non-hardware-dependent, always-safe edges of its public surface.
@MainActor
final class AudioCaptureServiceTests: XCTestCase {

    func test_initialState_isNotCapturing() {
        let service = AudioCaptureService()
        XCTAssertFalse(service.isCapturing)
    }

    func test_stop_withoutHavingStarted_returnsEmptyBuffer_andDoesNotCrash() {
        let service = AudioCaptureService()

        let samples = service.stop()

        XCTAssertTrue(samples.isEmpty)
        XCTAssertFalse(service.isCapturing)
    }

    func test_stop_isIdempotent_whenCalledRepeatedlyWithoutStarting() {
        let service = AudioCaptureService()

        XCTAssertTrue(service.stop().isEmpty)
        XCTAssertTrue(service.stop().isEmpty)
    }
}

/// Covers the real-time audio path without needing hardware: feeds a
/// synthetic PCM buffer straight into `AudioTapProcessor.process(_:)` — the
/// exact call `AVAudioEngine`'s tap block makes on the audio thread — and
/// asserts the converted samples land in the accumulator. This is what
/// previously crashed with `_dispatch_assert_queue_fail` when the
/// conversion/accumulation path was (incorrectly) `@MainActor`-isolated
/// under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; running it off the
/// main actor here (a plain, non-isolated test method, so the runtime
/// cannot silently forgive a main-thread assumption) proves the path is
/// truly `nonisolated`.
final class AudioTapProcessorTests: XCTestCase {

    func test_process_convertsSyntheticBuffer_andAccumulatesSamples() throws {
        let inputFormat = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)
        )
        let targetFormat = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        )
        let converter = try XCTUnwrap(AVAudioConverter(from: inputFormat, to: targetFormat))
        let accumulator = AudioSampleAccumulator()
        let processor = AudioTapProcessor(
            converter: converter,
            targetFormat: targetFormat,
            inputSampleRate: inputFormat.sampleRate,
            accumulator: accumulator
        )

        let frameCount: AVAudioFrameCount = 4_800 // 100 ms @ 48 kHz
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let channel = try XCTUnwrap(buffer.floatChannelData)[0]
        for i in 0..<Int(frameCount) {
            channel[i] = 0.5
        }

        // Runs the exact call `AVAudioEngine`'s (real-time, non-main) tap
        // block makes — synchronously, on this test's (non-main) thread.
        processor.process(buffer)

        let drained = accumulator.drain()
        XCTAssertFalse(drained.isEmpty, "expected the 48kHz->16kHz conversion to produce samples")
        XCTAssertTrue(drained.allSatisfy { $0.isFinite })
    }
}

final class LectureSpoolTests: XCTestCase {
    func test_spoolOverflowIsExplicit_andDoesNotPretendAudioWasStored() throws {
        let spool = try LectureAudioSpool(maxPendingBytes: 4)
        spool.append([0.1, 0.2])
        XCTAssertNotNil(spool.failure)
        XCTAssertTrue(spool.snapshot(0..<2).isEmpty)
    }

    func test_spoolReadsRangesAndReleasesMemoryForLongCapture() throws {
        let accumulator = AudioSampleAccumulator()
        try accumulator.useDiskStorage()
        let chunk = Array(repeating: Float(0.001), count: 16_000)
        for _ in 0..<120 { accumulator.append(chunk) }
        XCTAssertEqual(accumulator.count, 1_920_000)
        XCTAssertEqual(accumulator.snapshot(16_000..<32_000), chunk)
        XCTAssertEqual(accumulator.residentSampleCount, 0)
        XCTAssertNil(accumulator.storageFailure)
        accumulator.clear()
        XCTAssertEqual(accumulator.count, 0)
    }
}
