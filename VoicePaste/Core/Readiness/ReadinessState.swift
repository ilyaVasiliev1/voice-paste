import Foundation

/// `API-local-readiness` result type. UI must not start a recording session
/// unless the published state is exactly `.ready` (see `api.md`).
public enum ReadinessState: Equatable, Sendable {
    case ready
    case needsMicrophonePermission
    case needsAccessibilityPermission
    case needsModel
    case downloadingModel(progress: Double)
    case error(ReadinessError)

    /// Short, localizable-key reason shown as the disabled explanation in the
    /// menu (`UI-001`) and in onboarding (`UI-002`). Actual user-facing copy
    /// lives in `Localizable.strings`; this only picks the key.
    public var statusLocalizationKey: String {
        switch self {
        case .ready: return "readiness.status.ready"
        case .needsMicrophonePermission: return "readiness.status.needsMicrophone"
        case .needsAccessibilityPermission: return "readiness.status.needsAccessibility"
        case .needsModel: return "readiness.status.needsModel"
        case .downloadingModel: return "readiness.status.downloadingModel"
        case .error: return "readiness.status.error"
        }
    }
}

public enum ReadinessError: Error, Equatable, Sendable {
    case modelMissing
    case permissionDenied
}
