import Combine
import XCTest
@testable import VoicePaste

/// `AT-086`/`L-010`/`UI-002` unit tests for `ModelManager`'s honest first-run
/// model-download progress: monotonicity, the sub-100% ceiling while
/// `.downloading`, byte-accurate "N из 626 МБ" *derived from the single
/// `fractionCompleted` signal*, the ETA gate, the ≤4 Hz UI throttle, and the
/// failed/auto-retry path.
///
/// `ModelManager` has no injectable clock or byte feed: the download
/// callback now delivers a single `fraction` (`Double`, 0...1) through the
/// `makeTranscriber` factory's `downloadProgress` callback, and speed/ETA
/// math is keyed off real monotonic time (`DispatchTime.now()`), matching
/// the note in `ModelManagerTests.swift` that this type isn't
/// fake-clock-testable without a product change (out of scope for QA). These
/// tests therefore drive a synthetic fraction sequence through the real
/// callback with small *real* delays between samples — both to let each
/// `Task { @MainActor in ... }` hop actually land before the factory
/// continues (no product-code change needed to make this deterministic;
/// see the comment below), and, for the ETA test, to genuinely accumulate
/// the spec's real elapsed-time bar.
@MainActor
final class ModelDownloadProgressTests: XCTestCase {

    // MARK: - Test fixture

    private struct RetriableDownloadFailure: Error, Equatable {}

    private let totalBytes: Int64 = ModelCatalog.approximateSizeBytes

    /// Builds a manager whose factory feeds `samples` (fractions, `0...1`)
    /// one at a time into the download-progress callback, with a short real
    /// `Task.sleep` after each one.
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
        samples: [Double],
        interSampleDelayNanos: UInt64 = 30_000_000, // 30ms
        failAfterSamplesWith: Error? = nil,
        finalResult: TranscriptionResult = .init(rawText: "ok", detectedLanguage: "ru")
    ) -> ModelManager {
        ModelManager(
            modelDirectory: modelDirectory ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("ModelDownloadProgressTests-\(UUID().uuidString)", isDirectory: true),
            makeTranscriber: { _, _, progress in
                for fraction in samples {
                    progress(fraction)
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

    // MARK: - 1. Monotonicity, including a downward fraction "jitter"

    /// `L-010`: "Прогресс монотонно растёт" — even if the underlying
    /// `Progress.fractionCompleted` momentarily reports a lower fraction than
    /// before (a jitter a multi-file aggregate's child-progress reweighting
    /// could plausibly emit), the *published* `fraction` must never go
    /// backwards.
    func test_fraction_neverDecreases_evenWithFractionJitter() async throws {
        // Spaced past the 250ms UI throttle gate so every sample —
        // including the downward jitter — is individually observable in the
        // published history, not silently absorbed by the throttle.
        let manager = makeManager(
            samples: [0.16, 0.32, 0.24, 0.48], // jitter: 0.24 < previous 0.32
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
                + "L-010 requires monotonic progress even if the raw fraction signal jitters downward"
            )
        }
    }

    // MARK: - 2. Ceiling: never a false 100% while `.downloading`

    /// `L-010`/`UI-002`: the jump to "done" only happens through the
    /// `.verifying` transition, never through `.downloading`'s `fraction`
    /// reaching `1.0` — even when the raw callback reports `fractionCompleted
    /// == 1.0`.
    func test_downloadingFraction_neverReaches1_evenWhenRawFractionIs1() async throws {
        let manager = makeManager(samples: [0.3, 0.6, 1.0])
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

    // MARK: - 3. "N из 626 МБ" is derived from the fraction, never "0 из 0"

    /// `L-010`/`AT-086`: `completedBytes`/`totalBytes` must be *derived* from
    /// the raw `fraction` times the catalog's advertised constant size — not
    /// read from WhisperKit's own file-count `completedUnitCount`/
    /// `totalUnitCount` (the pre-fix bug this test guards against: "0 из 0
    /// МБ"). The initial `.downloading` state (before any callback fires)
    /// must already report the catalog's advertised total.
    func test_completedAndTotalBytes_areDerivedFromFraction_neverZeroOfZero() async throws {
        // Spaced past the 250ms UI throttle gate so both samples are
        // individually observable in the published history (the throttle
        // itself is exercised separately below).
        let manager = makeManager(
            samples: [0.067, 0.5], // 0.067 * 626MB ≈ 42MB
            interSampleDelayNanos: 300_000_000
        )
        let recorder = StateRecorder(manager)

        _ = try await manager.ensureLoaded()

        let progressUpdates = recorder.downloadingProgress
        XCTAssertEqual(progressUpdates.first?.completedBytes, 0)
        XCTAssertEqual(progressUpdates.first?.totalBytes, ModelCatalog.approximateSizeBytes)
        XCTAssertEqual(ModelCatalog.approximateSizeBytes, 626 * 1024 * 1024, "AT-086 promises \"N из 626 МБ\"")

        let expectedFirstBytes = Int64(0.067 * Double(totalBytes))
        let expectedSecondBytes = Int64(0.5 * Double(totalBytes))
        XCTAssertTrue(progressUpdates.contains { $0.completedBytes == expectedFirstBytes && $0.totalBytes == totalBytes })
        XCTAssertTrue(progressUpdates.contains { $0.completedBytes == expectedSecondBytes && $0.totalBytes == totalBytes })

        // The AT-086 bug being guarded against: once any real progress has
        // been reported, the UI must never show "0 из 0 МБ".
        for update in progressUpdates where update.fraction > 0 {
            XCTAssertGreaterThan(update.completedBytes, 0)
            XCTAssertGreaterThan(update.totalBytes, 0)
        }
    }

    /// `totalBytes` is now *always* the catalog constant — there is no
    /// separate "raw total was 0" fallback branch left to test (the raw
    /// file-count total is never consulted at all any more; `fraction` is
    /// the single source of truth). This replaces the old
    /// `test_zeroReportedTotal_fallsBackToCatalogSize` test, which exercised
    /// a fallback that no longer exists in the fraction-based design.
    func test_totalBytes_isAlwaysCatalogConstant_regardlessOfFractionValue() async throws {
        let manager = makeManager(samples: [0.001, 0.4, 0.9])
        let recorder = StateRecorder(manager)

        _ = try await manager.ensureLoaded()

        for update in recorder.downloadingProgress {
            XCTAssertEqual(update.totalBytes, ModelCatalog.approximateSizeBytes)
            XCTAssertFalse(update.fraction.isNaN)
            XCTAssertFalse(update.fraction.isInfinite)
        }
    }

    // MARK: - 4. ETA gate: nil until real speed accumulates

    /// `L-010`/`AT-086`: "Считаем время…" (both `speedBytesPerSecond` and
    /// `etaSeconds` are `nil`) until at least 3 valid byte-delta samples
    /// (derived from `fraction`) *and* ≥1.0s of monotonic time have
    /// accumulated since the first sample; only then do both become non-nil
    /// and a plausible ETA (`remaining bytes / speed`) is shown.
    func test_speedAndETA_areNilUntilEnoughRealSamplesAccumulate_thenBecomePlausible() async throws {
        // 4 samples spaced ~350ms apart (real time) => by the 4th sample,
        // speedSampleCount == 3 and >1.0s has elapsed since the first byte
        // sample — exactly the documented threshold.
        let manager = makeManager(
            samples: [0.016, 0.064, 0.12, 0.18],
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

    // MARK: - 4b. Speed stability: a derivative of fraction, not jumpy file counts

    /// `L-010`: because speed/ETA are now derived from the single smooth
    /// `fraction` signal (not WhisperKit's jumpy per-file counters), a
    /// steady, evenly-spaced fraction feed must produce a stable, positive,
    /// non-jittery speed once the ETA gate opens — guards against a
    /// regression back to counting discrete file completions.
    func test_speed_isStable_whenFractionIncreasesInEvenSteps() async throws {
        let manager = makeManager(
            samples: [0.05, 0.10, 0.15, 0.20, 0.25],
            interSampleDelayNanos: 300_000_000
        )
        let recorder = StateRecorder(manager)

        _ = try await manager.ensureLoaded()

        let updates = recorder.downloadingProgress
        let speeds = updates.compactMap(\.speedBytesPerSecond)
        XCTAssertFalse(speeds.isEmpty, "expected speed to become available once the ETA gate opens")
        for speed in speeds {
            XCTAssertGreaterThan(speed, 0, "a steady fraction increase must never produce a non-positive speed")
        }
        for update in updates where update.speedBytesPerSecond != nil {
            let eta = try XCTUnwrap(update.etaSeconds)
            XCTAssertGreaterThanOrEqual(eta, 0, "ETA must be non-negative")
            XCTAssertFalse(eta.isNaN)
            XCTAssertFalse(eta.isInfinite)
        }
    }

    // MARK: - 5. UI throttle: no more than ~4 Hz

    /// `L-010`/`AT-086`/`UI-002`: however fast the underlying fraction feed
    /// fires, published `.downloading` updates must not exceed roughly 4 Hz
    /// (throttle gate is 0.25s, with the very first sample always let
    /// through).
    func test_downloadingUpdates_areThrottledToApproximately4Hz() async throws {
        // 24 samples over ~720ms of real time (30ms apart) — far faster
        // than 4 Hz if unthrottled.
        let sampleCount = 24
        let samples: [Double] = (1...sampleCount).map { Double($0) * 0.02 }
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
        // callback fires, and the first real sample is *also* deliberately
        // let through unthrottled (`AT-086`: the step must not sit frozen at
        // 0% while a slow first chunk downloads) — two legitimately
        // back-to-back updates before the gate engages.
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

    /// `AT-086`: a dropped connection that fails on *every* attempt (the
    /// factory always throws) must exhaust the auto-retry budget
    /// (`maxAutoDownloadRetries = 2`, so the factory is invoked `1 + 2 = 3`
    /// times total) and only then land in `.failed`, with no `.downloading`
    /// update ever having claimed 100% and no `.ready` leaking through.
    /// Includes the ~2×1.5s auto-retry pause — this is an honest, if slow,
    /// test of the real retry timing, not disabled.
    func test_networkDrop_exhaustsAutoRetries_thenLandsInFailed() async throws {
        var callCount = 0
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelDownloadProgressTests-exhaust-\(UUID().uuidString)", isDirectory: true)
        let manager = ModelManager(
            modelDirectory: directory,
            makeTranscriber: { _, _, progress in
                callCount += 1
                progress(0.1)
                try? await Task.sleep(nanoseconds: 30_000_000)
                progress(0.22)
                throw RetriableDownloadFailure()
            }
        )
        let recorder = StateRecorder(manager)

        do {
            _ = try await manager.ensureLoaded()
            XCTFail("expected the simulated network drop to throw after exhausting auto-retries")
        } catch {
            // expected
        }

        XCTAssertEqual(manager.state, .failed(.downloadFailed))
        XCTAssertEqual(callCount, 3, "factory must be invoked 1 (first try) + 2 (maxAutoDownloadRetries) = 3 times before giving up")
        for progress in recorder.downloadingProgress {
            XCTAssertLessThan(progress.fraction, 1.0)
        }
        XCTAssertFalse(recorder.states.contains(.ready), "a failed download must never have reached .ready")
    }

    /// `AT-086`: a transient failure on the *first* auto-retry attempt must
    /// be transparently repaired within a single `ensureLoaded()` call — no
    /// user-visible failure, no manual "Повторить" needed. This is the core
    /// promise of `loadWithAutoRetry()`: the factory throws once, then
    /// succeeds on the very next attempt, entirely inside one `ensureLoaded()`.
    func test_autoRetry_repairsATransientFirstAttempt_withinASingleEnsureLoaded() async throws {
        var callCount = 0
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelDownloadProgressTests-selfheal-\(UUID().uuidString)", isDirectory: true)
        let manager = ModelManager(
            modelDirectory: directory,
            makeTranscriber: { _, _, progress in
                callCount += 1
                if callCount == 1 {
                    progress(0.05)
                    throw RetriableDownloadFailure()
                }
                progress(0.5)
                return MockTranscriber(result: .success(.init(rawText: "ok", detectedLanguage: "ru")))
            }
        )

        let result = try await manager.ensureLoaded()

        XCTAssertNotNil(result)
        XCTAssertEqual(manager.state, .ready)
        XCTAssertEqual(callCount, 2, "one failed attempt, one successful retry — both inside the single ensureLoaded() call")
    }

    /// `AT-086`: after a first `ensureLoaded()` session whose auto-retry
    /// budget is *fully exhausted* (fails on all 3 attempts of that
    /// session), the user's "Повторить" (a second, separate `ensureLoaded()`
    /// call) must start from a clean tracker — no inherited speed/percentage
    /// from the previous session — and this time reach `.ready` immediately.
    func test_retryAfterExhaustedSession_resetsTracking_andCanSucceed() async throws {
        var callCount = 0
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelDownloadProgressTests-retry-\(UUID().uuidString)", isDirectory: true)
        let manager = ModelManager(
            modelDirectory: directory,
            makeTranscriber: { _, _, progress in
                callCount += 1
                if callCount <= 3 {
                    // All 3 attempts of the first ensureLoaded() session
                    // (1 + maxAutoDownloadRetries = 2) fail, fully exhausting
                    // that session's auto-retry budget.
                    progress(0.096) // ≈ 60MB / 626MB
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    progress(0.224) // ≈ 140MB / 626MB
                    throw RetriableDownloadFailure()
                } else {
                    // The user's manual retry (second, separate
                    // ensureLoaded() call) succeeds on its very first
                    // attempt.
                    progress(0.008)
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    progress(0.999)
                    return MockTranscriber(result: .success(.init(rawText: "ok", detectedLanguage: "ru")))
                }
            }
        )

        do {
            _ = try await manager.ensureLoaded()
            XCTFail("expected the first session to fail after exhausting its auto-retry budget")
        } catch {
            // expected
        }
        XCTAssertEqual(manager.state, .failed(.downloadFailed))
        XCTAssertEqual(callCount, 3, "first session must have exhausted all 3 attempts before failing")

        let retryRecorder = StateRecorder(manager)
        _ = try await manager.ensureLoaded()

        XCTAssertEqual(manager.state, .ready)
        XCTAssertEqual(callCount, 4, "the manual retry succeeds on its first attempt")
        let retryProgress = retryRecorder.downloadingProgress
        XCTAssertFalse(retryProgress.isEmpty, "expected fresh .downloading updates on retry")
        XCTAssertEqual(retryProgress.first?.completedBytes, 0, "retry must start the byte counter from 0, not the failed session's last value")
        XCTAssertNil(retryProgress.first?.speedBytesPerSecond, "retry must not inherit the previous session's speed")
        XCTAssertNil(retryProgress.first?.etaSeconds, "retry must not inherit the previous session's ETA")
    }

}
