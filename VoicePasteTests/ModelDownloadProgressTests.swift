import Combine
import XCTest
@testable import VoicePaste

/// `AT-086`/`L-010`/`UI-002` unit tests for `ModelManager`'s honest first-run
/// model-download progress: monotonicity, the sub-100% ceiling while
/// `.downloading`, byte-accurate "N из 626 МБ", the ETA gate, the ≤4 Hz UI
/// throttle, and the failed/retry path.
///
/// `ModelManager` has no injectable clock or byte feed: the download's byte
/// counter is delivered through the `makeTranscriber` factory's
/// `downloadProgress` callback, and speed/ETA math is keyed off real
/// monotonic time (`DispatchTime.now()`), matching the note in
/// `ModelManagerTests.swift` that this type isn't fake-clock-testable
/// without a product change (out of scope for QA). These tests therefore
/// drive a synthetic byte sequence through the real callback with small
/// *real* delays between samples — both to let each
/// `Task { @MainActor in ... }` hop actually land before the factory
/// continues (no product-code change needed to make this deterministic;
/// see the comment below), and, for the ETA test, to genuinely accumulate
/// the spec's real elapsed-time bar.
@MainActor
final class ModelDownloadProgressTests: XCTestCase {

    // MARK: - Test fixture

    private struct RetriableDownloadFailure: Error, Equatable {}

    private let totalBytes: Int64 = ModelCatalog.approximateSizeBytes

    /// Builds a manager whose factory feeds `samples` one at a time into the
    /// download-progress callback, with a short real `Task.sleep` after each
    /// one.
    ///
    /// The sleep is not just pacing: `handleDownloadProgress` is invoked via
    /// `Task { @MainActor in ... }` from inside the (non-actor-isolated)
    /// progress callback. Because this factory closure itself keeps running
    /// on the caller's (`ModelManager`'s `@MainActor`) executor without
    /// hitting a suspension point, a purely synchronous burst of
    /// `progress(...)` calls would queue every `handleDownloadProgress` hop
    /// *behind* the whole `ensureLoaded()` call — by the time they ran,
    /// `state` would already be `.ready`/`.failed` and every hop would be a
    /// no-op (`guard case .downloading = state else { return }`). The sleep
    /// gives each queued hop a real chance to run before the next sample.
    private func makeManager(
        modelDirectory: URL? = nil,
        samples: [(completed: Int64, total: Int64)],
        interSampleDelayNanos: UInt64 = 30_000_000, // 30ms
        failAfterSamplesWith: Error? = nil,
        finalResult: TranscriptionResult = .init(rawText: "ok", detectedLanguage: "ru")
    ) -> ModelManager {
        ModelManager(
            modelDirectory: modelDirectory ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("ModelDownloadProgressTests-\(UUID().uuidString)", isDirectory: true),
            makeTranscriber: { _, progress in
                for sample in samples {
                    progress(sample.completed, sample.total)
                    try? await Task.sleep(nanoseconds: interSampleDelayNanos)
                }
                if let failAfterSamplesWith {
                    throw failAfterSamplesWith
                }
                return MockTranscriber(result: .success(finalResult))
            }
        )
    }

    /// Records every published `state` transition (and the wall-clock time
    /// it arrived) for later inspection, since `ModelManager` doesn't expose
    /// its own history.
    @MainActor
    private final class StateRecorder {
        private(set) var states: [ModelState] = []
        private(set) var receivedAt: [Date] = []
        private var cancellable: AnyCancellable?

        init(_ manager: ModelManager) {
            cancellable = manager.$state.sink { [weak self] value in
                self?.states.append(value)
                self?.receivedAt.append(Date())
            }
        }

        var downloadingProgress: [ModelDownloadProgress] {
            states.compactMap {
                if case .downloading(let progress) = $0 { return progress }
                return nil
            }
        }
    }

    // MARK: - 1. Monotonicity, including a downward byte "jitter"

    /// `L-010`: "Прогресс монотонно растёт" — even if the underlying byte
    /// counter momentarily reports fewer completed bytes than before (a
    /// jitter WhisperKit's `Progress` could plausibly emit), the *published*
    /// `fraction` must never go backwards.
    func test_fraction_neverDecreases_evenWithByteCounterJitter() async throws {
        // Spaced past the 250ms UI throttle gate so every sample —
        // including the downward jitter — is individually observable in the
        // published history, not silently absorbed by the throttle.
        let manager = makeManager(
            samples: [
                (100_000_000, totalBytes),
                (200_000_000, totalBytes),
                (150_000_000, totalBytes), // jitter: fewer bytes than the previous sample
                (300_000_000, totalBytes),
            ],
            interSampleDelayNanos: 300_000_000
        )
        let recorder = StateRecorder(manager)

        _ = try await manager.ensureLoaded()

        let fractions = recorder.downloadingProgress.map(\.fraction)
        XCTAssertEqual(fractions.count, 5, "expected the initial placeholder plus all 4 fed samples to be individually published")
        for index in 1..<fractions.count {
            XCTAssertGreaterThanOrEqual(
                fractions[index], fractions[index - 1],
                "fraction regressed at update \(index): \(fractions[index - 1]) -> \(fractions[index]); "
                + "L-010 requires monotonic progress even if the raw byte counter jitters downward"
            )
        }
    }

    // MARK: - 2. Ceiling: never a false 100% while `.downloading`

    /// `L-010`/`UI-002`: the jump to "done" only happens through the
    /// `.verifying` transition, never through `.downloading`'s `fraction`
    /// reaching `1.0` — even when fed `completed == total`.
    func test_downloadingFraction_neverReaches1_evenAtCompletedEqualsTotal() async throws {
        let manager = makeManager(samples: [
            (300_000_000, totalBytes),
            (600_000_000, totalBytes),
            (totalBytes, totalBytes), // fully "complete" byte-wise, still mid-download
        ])
        let recorder = StateRecorder(manager)

        _ = try await manager.ensureLoaded()

        for progress in recorder.downloadingProgress {
            XCTAssertLessThan(progress.fraction, 1.0, "no .downloading update may report 100%")
            XCTAssertLessThanOrEqual(progress.fraction, 0.999)
        }
        // The 100%/ready story is told exclusively by the state transition,
        // not by a `.downloading` value.
        XCTAssertTrue(recorder.states.contains(.verifying))
        XCTAssertEqual(manager.state, .ready)
    }

    // MARK: - 3. "N из 626 МБ" comes from the byte counters, not a timer

    /// `L-010`: percent/"N из 626 МБ" must be read straight from
    /// `completedBytes`/`totalBytes` as fed by the loader, and the initial
    /// `.downloading` state (before any callback fires) must already report
    /// the catalog's advertised total.
    func test_completedAndTotalBytes_matchFedCounters_notASyntheticTimer() async throws {
        // Spaced past the 250ms UI throttle gate so both samples are
        // individually observable in the published history (the throttle
        // itself is exercised separately below).
        let manager = makeManager(
            samples: [
                (42_000_000, totalBytes),
                (313_000_000, totalBytes),
            ],
            interSampleDelayNanos: 300_000_000
        )
        let recorder = StateRecorder(manager)

        _ = try await manager.ensureLoaded()

        let progressUpdates = recorder.downloadingProgress
        XCTAssertEqual(progressUpdates.first?.completedBytes, 0)
        XCTAssertEqual(progressUpdates.first?.totalBytes, ModelCatalog.approximateSizeBytes)
        XCTAssertEqual(ModelCatalog.approximateSizeBytes, 626 * 1024 * 1024, "AT-086 promises \"N из 626 МБ\"")

        XCTAssertTrue(progressUpdates.contains { $0.completedBytes == 42_000_000 && $0.totalBytes == totalBytes })
        XCTAssertTrue(progressUpdates.contains { $0.completedBytes == 313_000_000 && $0.totalBytes == totalBytes })
    }

    /// Guards the documented fallback: a momentary `totalUnitCount == 0` from
    /// the underlying `Progress` must not divide-by-zero or leak a `0` total
    /// into the UI — it must fall back to the catalog's advertised size.
    func test_zeroReportedTotal_fallsBackToCatalogSize_notZeroOrNaN() async throws {
        let manager = makeManager(samples: [
            (10_000_000, 0), // WhisperKit's momentary `totalUnitCount == 0` glitch
        ])
        let recorder = StateRecorder(manager)

        _ = try await manager.ensureLoaded()

        let update = recorder.downloadingProgress.first { $0.completedBytes == 10_000_000 }
        XCTAssertEqual(update?.totalBytes, ModelCatalog.approximateSizeBytes)
        XCTAssertNotNil(update)
        if let fraction = update?.fraction {
            XCTAssertFalse(fraction.isNaN)
            XCTAssertFalse(fraction.isInfinite)
        }
    }

    // MARK: - 4. ETA gate: nil until real speed accumulates

    /// `L-010`/`AT-086`: "Считаем время…" (both `speedBytesPerSecond` and
    /// `etaSeconds` are `nil`) until at least 3 valid byte-delta samples
    /// *and* ≥1.0s of monotonic time have accumulated since the first
    /// sample; only then do both become non-nil and a plausible ETA
    /// (`remaining bytes / speed`) is shown.
    func test_speedAndETA_areNilUntilEnoughRealSamplesAccumulate_thenBecomePlausible() async throws {
        // 4 samples spaced ~350ms apart (real time) => by the 4th sample,
        // speedSampleCount == 3 and >1.0s has elapsed since the first byte
        // sample — exactly the documented threshold.
        let manager = makeManager(
            samples: [
                (10_000_000, totalBytes),
                (40_000_000, totalBytes),
                (75_000_000, totalBytes),
                (115_000_000, totalBytes),
            ],
            interSampleDelayNanos: 350_000_000
        )
        let recorder = StateRecorder(manager)

        _ = try await manager.ensureLoaded()

        let updates = recorder.downloadingProgress
        XCTAssertGreaterThanOrEqual(updates.count, 4, "expected all 4 samples to pass the ≥250ms UI throttle")

        for early in updates.prefix(3) {
            XCTAssertNil(early.speedBytesPerSecond, "\"Считаем время…\" must hold before the threshold")
            XCTAssertNil(early.etaSeconds)
        }

        guard let last = updates.last else {
            return XCTFail("expected at least one downloading update")
        }
        let speed = try XCTUnwrap(last.speedBytesPerSecond, "speed must appear once ≥3 samples and ≥1.0s have passed")
        let eta = try XCTUnwrap(last.etaSeconds)
        XCTAssertGreaterThan(speed, 0)
        let expectedETA = Double(totalBytes - last.completedBytes) / speed
        XCTAssertEqual(eta, expectedETA, accuracy: 0.01, "ETA must be remaining bytes / smoothed speed")
    }

    // MARK: - 5. UI throttle: no more than ~4 Hz

    /// `L-010`/`AT-086`/`UI-002`: however fast the underlying byte feed
    /// fires, published `.downloading` updates must not exceed roughly 4 Hz
    /// (throttle gate is 0.25s, with the very first sample always let
    /// through).
    func test_downloadingUpdates_areThrottledToApproximately4Hz() async throws {
        // 24 samples over ~720ms of real time (30ms apart) — far faster
        // than 4 Hz if unthrottled.
        let sampleCount = 24
        let samples: [(completed: Int64, total: Int64)] = (1...sampleCount).map {
            (Int64($0) * 5_000_000, totalBytes)
        }
        let manager = makeManager(samples: samples, interSampleDelayNanos: 30_000_000)
        let recorder = StateRecorder(manager)

        _ = try await manager.ensureLoaded()

        let publishedCount = recorder.downloadingProgress.count
        XCTAssertLessThan(
            publishedCount, sampleCount,
            "24 fast samples must not all reach the UI unthrottled"
        )
        // ~720ms of real elapsed time at a 0.25s gate allows at most ~4
        // updates, +1 for the always-let-through first sample; allow a
        // small margin for CI scheduling jitter.
        XCTAssertLessThanOrEqual(publishedCount, 6, "throttle must bound updates to roughly 4 Hz, not stream every sample")

        // Cross-check via wall-clock receive times: consecutive published
        // downloading updates should be spaced close to the 0.25s gate
        // (generous lower bound for CI jitter), not back-to-back. The very
        // first pair is exempt by design: `load()` sets an initial
        // unthrottled `.downloading(fraction: 0)` placeholder before any
        // callback fires, and the first real byte sample is *also*
        // deliberately let through unthrottled (`AT-086`: the step must not
        // sit frozen at 0% while a slow first chunk downloads) — two
        // legitimately back-to-back updates before the gate engages.
        let downloadingIndices = recorder.states.indices.filter {
            if case .downloading = recorder.states[$0] { return true }
            return false
        }
        if downloadingIndices.count >= 3 {
            for pair in zip(downloadingIndices.dropFirst(), downloadingIndices.dropFirst(2)) {
                let gap = recorder.receivedAt[pair.1].timeIntervalSince(recorder.receivedAt[pair.0])
                XCTAssertGreaterThanOrEqual(gap, 0.15, "throttled updates should be spaced near the 0.25s gate")
            }
        }
    }

    // MARK: - 6. Failed state has no fake progress; retry resets tracking

    /// `AT-086`: a dropped connection lands in `.failed` with no
    /// `.downloading` update ever having claimed 100%, and no `.ready`
    /// leaking through.
    func test_networkDrop_landsInFailed_withNoFakeCompleteProgress() async throws {
        let manager = makeManager(
            samples: [(60_000_000, totalBytes), (140_000_000, totalBytes)],
            failAfterSamplesWith: RetriableDownloadFailure()
        )
        let recorder = StateRecorder(manager)

        do {
            _ = try await manager.ensureLoaded()
            XCTFail("expected the simulated network drop to throw")
        } catch {
            // expected
        }

        XCTAssertEqual(manager.state, .failed(.downloadFailed))
        for progress in recorder.downloadingProgress {
            XCTAssertLessThan(progress.fraction, 1.0)
        }
        XCTAssertFalse(recorder.states.contains(.ready), "a failed download must never have reached .ready")
    }

    /// `AT-086`: after a failed first attempt, the user's "Повторить" (a
    /// second `ensureLoaded()` call) must start from a clean tracker — no
    /// inherited speed/percentage from the previous attempt — and this time
    /// reach `.ready`.
    func test_retryAfterFailure_resetsTracking_andCanSucceed() async throws {
        var callCount = 0
        let total = totalBytes
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelDownloadProgressTests-retry-\(UUID().uuidString)", isDirectory: true)
        let manager = ModelManager(
            modelDirectory: directory,
            makeTranscriber: { _, progress in
                callCount += 1
                if callCount == 1 {
                    progress(60_000_000, total)
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    progress(140_000_000, total)
                    throw RetriableDownloadFailure()
                } else {
                    progress(5_000_000, total)
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    progress(total, total)
                    return MockTranscriber(result: .success(.init(rawText: "ok", detectedLanguage: "ru")))
                }
            }
        )

        do {
            _ = try await manager.ensureLoaded()
            XCTFail("expected the first attempt to fail")
        } catch {
            // expected
        }
        XCTAssertEqual(manager.state, .failed(.downloadFailed))

        let retryRecorder = StateRecorder(manager)
        _ = try await manager.ensureLoaded()

        XCTAssertEqual(manager.state, .ready)
        let retryProgress = retryRecorder.downloadingProgress
        XCTAssertFalse(retryProgress.isEmpty, "expected fresh .downloading updates on retry")
        XCTAssertEqual(retryProgress.first?.completedBytes, 0, "retry must start the byte counter from 0, not the failed attempt's last value")
        XCTAssertNil(retryProgress.first?.speedBytesPerSecond, "retry must not inherit the previous attempt's speed")
        XCTAssertNil(retryProgress.first?.etaSeconds, "retry must not inherit the previous attempt's ETA")
    }

}
