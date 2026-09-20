import Foundation
import ServiceManagement

/// Abstraction over `SMAppService.mainApp` (`L-020`) so `AppSettings` never
/// hard-codes the real system registry. Tests substitute a fake conforming
/// to this protocol instead of ever touching the actual Login Items
/// registry — `SMAppService.mainApp.register()`/`unregister()` are real
/// system side effects with no in-memory reset between test runs.
/// `nonisolated` throughout: the project defaults undeclared isolation to
/// `@MainActor` (`SWIFT_DEFAULT_ACTOR_ISOLATION`), but `register()`/
/// `unregister()` are blocking system/XPC round-trips that `AppSettings`
/// deliberately calls off the main actor (`INV-009`) — the protocol must not
/// force them back onto it.
public protocol LoginItemRegistering: Sendable {
    /// The system's own answer for whether VoicePaste is registered — the
    /// single source of truth `L-020` requires. Any value other than
    /// `.enabled` reads as "off".
    nonisolated var status: SMAppService.Status { get }
    /// Registers the main app as a login item. Idempotent per
    /// `SMAppService`'s own contract: calling it while already `.enabled`
    /// neither throws nor creates a second entry.
    nonisolated func register() throws
    /// Removes the login item registration.
    nonisolated func unregister() throws
}

/// The real system registry — a thin pass-through to `SMAppService.mainApp`.
/// Both calls are synchronous system/XPC round-trips, so callers must invoke
/// them off the main actor (`INV-009`); this type itself has no opinion on
/// which queue it runs on.
public struct SystemLoginItemRegistry: LoginItemRegistering {
    public init() {}

    public nonisolated var status: SMAppService.Status { SMAppService.mainApp.status }

    public nonisolated func register() throws {
        try SMAppService.mainApp.register()
    }

    public nonisolated func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

/// A registry that never touches the real system: reports permanently
/// `.notRegistered` and treats `register()`/`unregister()` as no-ops. Used as
/// `AppSettings`'s default under `ProcessRuntime.isRunningTests` (`L-020`,
/// `L-018`) — the test host is itself a copy of VoicePaste, so without this
/// guard a stray test could flip the Login Items entry of whichever copy
/// happens to be installed on the machine running the suite.
public struct NullLoginItemRegistry: LoginItemRegistering {
    public init() {}
    public nonisolated var status: SMAppService.Status { .notRegistered }
    public nonisolated func register() throws {}
    public nonisolated func unregister() throws {}
}
