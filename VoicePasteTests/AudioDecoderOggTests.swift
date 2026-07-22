import XCTest
@testable import VoicePaste

/// Gate 2 integration test for `AudioDecoder` against a **real** Telegram
/// OGG/Opus voice-message fixture (`L-009`, `DEP-008`, `US-007`) — no
/// network, no third-party OGG/Opus library, purely `AVAudioFile` +
/// `AVAudioConverter`.
///
/// ## AT-024 status: `blocked`, not `passed`
/// `spec/_tests.md` AT-024 requires **two** real, obfuscated Telegram
/// samples ("Оба декодируются локально... Без `passed` для этого теста v1
/// не принимается"). `VoicePasteTests/Fixtures/TelegramOGG/` currently
/// contains exactly **one** (`sample-01.ogg`), per that directory's own
/// `README.md`. This test file proves the decoder path works end-to-end on
/// the sample that does exist (closing the `DEP-008` risk spike at the code
/// level), but it deliberately cannot and does not claim `AT-024 = passed`
/// — that requires `sample-02.ogg` to be added and this suite extended
/// before v1 ships. See the final QA report for the explicit gate status.
/// Lock-protected sink for the `@Sendable` progress callback — a plain
/// captured `var` would trip Swift 6 strict concurrency here since the
/// closure type itself is `Sendable` even though `AudioDecoder.decode` in
/// practice only calls it sequentially from within the awaited call.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 0

    func set(_ newValue: Double) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
final class AudioDecoderOggTests: XCTestCase {

    private var sample01URL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/TelegramOGG/sample-01.ogg")
    }

    /// The one real Telegram OGG/Opus fixture is deliberately gitignored
    /// (`.gitignore`: real voice messages may carry PII), so it exists on a
    /// working checkout with the private assets but is absent on a fresh
    /// `git clone` / CI. Fixture-dependent tests **skip** — rather than fail —
    /// when it is missing, so a clean checkout's suite stays green while local
    /// runs still exercise the real end-to-end decode path.
    private func requireSample01URL() throws -> URL {
        let url = sample01URL
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "Telegram OGG/Opus fixture absent (gitignored — possible PII); skipping on clean checkout/CI"
        )
        return url
    }

    func test_fixtureFile_isPresentOnDisk() throws {
        // Local guarantee only: on a clean checkout / CI the fixture is
        // gitignored and absent, so this skips instead of failing.
        _ = try requireSample01URL()
    }

    /// Proves the real Telegram OGG/Opus sample decodes locally (no network)
    /// into the 16 kHz mono Float32 format every `Transcribing` conformer and
    /// `AudioCaptureService` agree on.
    func test_realTelegramSample_decodesLocally_to16kHzMonoFloat32() async throws {
        let sample01URL = try requireSample01URL()
        let decoder = AudioDecoder()
        let progressBox = ProgressBox()

        let samples = try await decoder.decode(url: sample01URL) { progress in
            progressBox.set(progress)
        }

        XCTAssertFalse(samples.isEmpty)
        // README documents ~132.36s at the source; resampled to 16 kHz that
        // is roughly 2,117,760 samples — assert a generous tolerance rather
        // than an exact count (Opus frame boundaries/priming samples make
        // the exact figure an implementation detail, not a contract).
        let expectedSampleCount = 132.36 * 16_000
        XCTAssertEqual(Double(samples.count), expectedSampleCount, accuracy: expectedSampleCount * 0.05)
        XCTAssertEqual(progressBox.get(), 1.0, accuracy: 0.01)
    }

    func test_realTelegramSample_probeDuration_matchesReadmeApproximateLength() throws {
        let sample01URL = try requireSample01URL()
        let decoder = AudioDecoder()

        let duration = decoder.probeDuration(url: sample01URL)

        let unwrapped = try? XCTUnwrap(duration)
        XCTAssertEqual(unwrapped ?? 0, 132.36, accuracy: 1.0)
    }

    /// The decoded buffer must actually be usable by the rest of the
    /// pipeline — i.e. produce a well-formed `TranscriptionRequest` (this
    /// doesn't invoke a real transcriber; it only proves the shapes line up,
    /// keeping this test network/model-free per the gate's mocking rule).
    func test_decodedSamples_canFormAValidTranscriptionRequest() async throws {
        let sample01URL = try requireSample01URL()
        let decoder = AudioDecoder()
        let samples = try await decoder.decode(url: sample01URL)

        let request = TranscriptionRequest(samples: samples, language: .auto)

        XCTAssertEqual(request.sampleRate, 16_000)
        XCTAssertFalse(request.samples.isEmpty)
    }

    // MARK: - EC-009/EC-010: decoder-level error handling (no history, honest error)

    func test_unsupportedExtension_throwsUnsupportedFormat() async throws {
        let decoder = AudioDecoder()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("note-\(UUID().uuidString).xyz")
        try Data("not audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try await decoder.decode(url: url)
            XCTFail("Expected AudioDecodeError.unsupportedFormat")
        } catch AudioDecodeError.unsupportedFormat {
            // expected
        }
    }

    /// `EC-010`: "при повреждённом файле показать точную диагностируемую
    /// ошибку" — a corrupted `.ogg` must fail with `decodeFailed`, not crash
    /// and not silently produce empty/garbage samples.
    func test_corruptedOggFile_throwsDecodeFailed_notCrash() async throws {
        let decoder = AudioDecoder()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("broken-\(UUID().uuidString).ogg")
        try Data([0x4F, 0x67, 0x67, 0x53, 0x00, 0x01, 0x02]).write(to: url) // "OggS" magic + garbage, not a real stream
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try await decoder.decode(url: url)
            XCTFail("Expected AudioDecodeError.decodeFailed for a corrupted OGG file")
        } catch AudioDecodeError.decodeFailed {
            // expected
        }
    }
}
