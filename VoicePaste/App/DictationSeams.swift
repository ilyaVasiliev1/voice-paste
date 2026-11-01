import Foundation

/// Микрофон так, как его видит тракт диктовки; в тестах вместо него подставной.
@MainActor
protocol AudioSource: AnyObject {
    var isCapturing: Bool { get }
    var lastCaptureRMS: Float { get }
    var capturedSampleCount: Int { get }
    var onLevel: ((Float) -> Void)? { get set }
    var onAudioChunk: (@Sendable ([Float]) -> Void)? { get set }
    var onInterruption: ((AudioCaptureInterruption) -> Void)? { get set }

    var captureStorageFailure: String? { get }
    func startLecture() throws
    func stopPreservingSamples() -> Int
    func resetCapturedSamples()
    func start() throws
    func resume() throws
    func pause()
    @discardableResult func stop() -> [Float]
    func capturedSamples(in range: Range<Int>) -> [Float]
}

extension AudioSource {
    var captureStorageFailure: String? { nil }
    func startLecture() throws { try start() }
    func stopPreservingSamples() -> Int { pause(); return capturedSampleCount }
    func resetCapturedSamples() { _ = stop() }
}

extension AudioCaptureService: AudioSource {}

@MainActor
protocol TextDelivering {
    func captureFrontApp() -> FrontAppSnapshot?
    func insert(_ text: String, into snapshot: FrontAppSnapshot?) -> InsertionOutcome
    func copyToClipboard(_ text: String)
}

struct SystemTextDelivery: TextDelivering {
    func captureFrontApp() -> FrontAppSnapshot? { TextInserter.captureFrontAppSnapshot() }

    func insert(_ text: String, into snapshot: FrontAppSnapshot?) -> InsertionOutcome {
        TextInserter().insert(text, into: snapshot)
    }

    func copyToClipboard(_ text: String) { TextInserter.copyToClipboard(text) }
}

/// Только то, что нужно тракту; действия кнопок плашки принадлежат дорожке интерфейса.
@MainActor
protocol HUDPresenting: AnyObject {
    func present(_ state: HUDState)
    func hide()
}

extension HUDWindowController: HUDPresenting {}
