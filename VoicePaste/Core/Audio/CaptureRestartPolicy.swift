import Foundation

/// Перезапуск захвата после смены устройства: гарнитура сразу после уведомления
/// часто ещё не готова, поэтому несколько попыток с короткой паузой.
nonisolated public enum CaptureRestartPolicy {
    public static func run(
        attempts: Int = 3,
        pause: Duration = .milliseconds(150),
        isolation: isolated (any Actor)? = #isolation,
        restart: () throws -> Void,
        sleep: (Duration) async -> Void
    ) async -> AudioCaptureInterruption {
        var lastError: Error = CancellationError()
        for attempt in 0..<max(1, attempts) {
            do {
                try restart()
                return .restarted
            } catch is CancellationError {
                return .failed(ErrorSummary.describe(CancellationError()))
            } catch {
                lastError = error
                if attempt < attempts - 1 { await sleep(pause) }
            }
        }
        return .failed(ErrorSummary.describe(lastError))
    }
}
