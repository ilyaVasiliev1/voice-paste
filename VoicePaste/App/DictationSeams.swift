import Foundation

/// Микрофон так, как его видит тракт диктовки. Настоящий — `AudioCaptureService`;
/// в тестах вместо него стоит подставной, и тракт проходит без звукового устройства.
@MainActor
protocol AudioSource: AnyObject {
    var isCapturing: Bool { get }
    var lastCaptureRMS: Float { get }
    var capturedSampleCount: Int { get }
    var onLevel: ((Float) -> Void)? { get set }
    var onAudioChunk: (@Sendable ([Float]) -> Void)? { get set }
    var onInterruption: ((AudioCaptureInterruption) -> Void)? { get set }

    func start() throws
    func resume() throws
    func pause()
    @discardableResult func stop() -> [Float]
    func capturedSamples(in range: Range<Int>) -> [Float]
}

extension AudioCaptureService: AudioSource {}

/// Доставка готового текста: чужое приложение или буфер обмена.
@MainActor
protocol TextDelivering {
    func captureFrontApp() -> FrontAppSnapshot?
    func insert(_ text: String, into snapshot: FrontAppSnapshot?) -> InsertionOutcome
    func copyToClipboard(_ text: String)
}

/// Настоящая доставка — прежний `TextInserter`, без изменений.
struct SystemTextDelivery: TextDelivering {
    func captureFrontApp() -> FrontAppSnapshot? { TextInserter.captureFrontAppSnapshot() }

    func insert(_ text: String, into snapshot: FrontAppSnapshot?) -> InsertionOutcome {
        TextInserter().insert(text, into: snapshot)
    }

    func copyToClipboard(_ text: String) { TextInserter.copyToClipboard(text) }
}

/// То, что тракту нужно от плашки: показать состояние и убрать её.
/// Остальную поверхность `HUDWindowController` (действия кнопок) знает только
/// сам контроллер — она принадлежит дорожке интерфейса.
@MainActor
protocol HUDPresenting: AnyObject {
    func present(_ state: HUDState)
    func hide()
}

extension HUDWindowController: HUDPresenting {}
