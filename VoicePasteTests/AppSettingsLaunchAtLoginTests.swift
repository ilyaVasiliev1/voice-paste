import ServiceManagement
import XCTest

@testable import VoicePaste

/// `L-020` — the login-item switch reads its position from
/// `SMAppService.mainApp.status` and only ever talks to the system through
/// `LoginItemRegistering`. Every test substitutes `FakeLoginItemRegistry`;
/// the real system registry is exercised only by the live verification in
/// `artifacts/evidence/T-0011/run.md`, never from this target.
@MainActor
final class AppSettingsLaunchAtLoginTests: XCTestCase {

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "AppSettingsLaunchAtLoginTests-\(UUID().uuidString)"
        return try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    private func clean(_ defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
    }

    /// Clean machine, nothing registered yet: the switch reads "выключено"
    /// straight from the system, and construction itself never touches the
    /// registry.
    func test_default_isOff_onCleanRegistry_andNothingIsRegistered() throws {
        let defaults = try makeIsolatedDefaults()
        defer { clean(defaults) }
        let registry = FakeLoginItemRegistry(initialStatus: .notRegistered)

        let settings = AppSettings(defaults: defaults, loginItemRegistry: registry)

        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertEqual(registry.registerCallCount, 0)
        XCTAssertEqual(registry.unregisterCallCount, 0)
    }

    /// Any status other than `.enabled` — including one that could look
    /// "half on" like `.requiresApproval` — must read as off, and none of
    /// them cause `AppSettings` to register or unregister on its own.
    func test_nonEnabledStatuses_allShowAsOff_andInitNeverTouchesRegistry() throws {
        for status: SMAppService.Status in [.notRegistered, .requiresApproval, .notFound] {
            let defaults = try makeIsolatedDefaults()
            defer { clean(defaults) }
            let registry = FakeLoginItemRegistry(initialStatus: status)

            let settings = AppSettings(defaults: defaults, loginItemRegistry: registry)

            XCTAssertFalse(settings.launchAtLogin, "status \(status) must read as off")
            XCTAssertEqual(registry.registerCallCount, 0, "status \(status) must not trigger a register")
            XCTAssertEqual(registry.unregisterCallCount, 0, "status \(status) must not trigger an unregister")
        }
    }

    /// A machine that already has VoicePaste registered from a previous
    /// session (e.g. after a relaunch) must read as on immediately, again
    /// without `AppSettings` calling into the registry itself.
    func test_alreadyEnabledOnDisk_readsAsOn_withoutRegisteringAgain() throws {
        let defaults = try makeIsolatedDefaults()
        defer { clean(defaults) }
        let registry = FakeLoginItemRegistry(initialStatus: .enabled)

        let settings = AppSettings(defaults: defaults, loginItemRegistry: registry)

        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertEqual(registry.registerCallCount, 0)
    }

    /// Flipping the switch on calls through to `register()` and, once the
    /// system reports `.enabled`, the switch reflects it.
    func test_enabling_registersWithSystem_andReflectsEnabledStatus() async throws {
        let defaults = try makeIsolatedDefaults()
        defer { clean(defaults) }
        let registry = FakeLoginItemRegistry(initialStatus: .notRegistered)
        registry.statusAfterRegister = .enabled
        let settings = AppSettings(defaults: defaults, loginItemRegistry: registry)

        settings.launchAtLogin = true
        await settings.waitForLoginItemRequestForTesting()

        XCTAssertEqual(registry.registerCallCount, 1)
        XCTAssertEqual(registry.unregisterCallCount, 0)
        XCTAssertTrue(settings.launchAtLogin)
    }

    /// Flipping the switch off calls through to `unregister()` and the
    /// switch follows the system back to off.
    func test_disabling_whenEnabled_unregistersWithSystem_andReflectsOff() async throws {
        let defaults = try makeIsolatedDefaults()
        defer { clean(defaults) }
        let registry = FakeLoginItemRegistry(initialStatus: .enabled)
        registry.statusAfterUnregister = .notRegistered
        let settings = AppSettings(defaults: defaults, loginItemRegistry: registry)
        XCTAssertTrue(settings.launchAtLogin)

        settings.launchAtLogin = false
        await settings.waitForLoginItemRequestForTesting()

        XCTAssertEqual(registry.unregisterCallCount, 1)
        XCTAssertFalse(settings.launchAtLogin)
    }

    /// `register()` throwing must not leave the switch on: it snaps back to
    /// the system's actual (untouched) status within the same interaction.
    func test_registerFailure_revertsSwitch_toActualSystemState() async throws {
        let defaults = try makeIsolatedDefaults()
        defer { clean(defaults) }
        let registry = FakeLoginItemRegistry(initialStatus: .notRegistered)
        registry.registerError = NSError(domain: "AppSettingsLaunchAtLoginTests", code: 1)
        let settings = AppSettings(defaults: defaults, loginItemRegistry: registry)

        settings.launchAtLogin = true
        await settings.waitForLoginItemRequestForTesting()

        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertEqual(registry.status, .notRegistered)
    }

    /// `unregister()` throwing must not leave the switch off if the system
    /// is, in fact, still registered.
    func test_unregisterFailure_revertsSwitch_toActualSystemState() async throws {
        let defaults = try makeIsolatedDefaults()
        defer { clean(defaults) }
        let registry = FakeLoginItemRegistry(initialStatus: .enabled)
        registry.unregisterError = NSError(domain: "AppSettingsLaunchAtLoginTests", code: 2)
        let settings = AppSettings(defaults: defaults, loginItemRegistry: registry)

        settings.launchAtLogin = false
        await settings.waitForLoginItemRequestForTesting()

        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertEqual(registry.status, .enabled)
    }

    /// `SMAppService.register()` can return without throwing while the
    /// resulting status is `.requiresApproval` rather than `.enabled` (system
    /// approval pending) — the switch must follow the real status, not just
    /// "the call didn't throw".
    func test_registerSucceeds_butStatusStaysRequiresApproval_revertsSwitchToOff() async throws {
        let defaults = try makeIsolatedDefaults()
        defer { clean(defaults) }
        let registry = FakeLoginItemRegistry(initialStatus: .notRegistered)
        registry.statusAfterRegister = .requiresApproval
        let settings = AppSettings(defaults: defaults, loginItemRegistry: registry)

        settings.launchAtLogin = true
        await settings.waitForLoginItemRequestForTesting()

        XCTAssertFalse(settings.launchAtLogin)
    }

    /// A full off→on round trip calls the registry exactly once per actual
    /// transition — no duplicate or wasted calls.
    func test_toggleOffThenOn_roundTrips_withoutDuplicateCalls() async throws {
        let defaults = try makeIsolatedDefaults()
        defer { clean(defaults) }
        let registry = FakeLoginItemRegistry(initialStatus: .enabled)
        registry.statusAfterUnregister = .notRegistered
        registry.statusAfterRegister = .enabled
        let settings = AppSettings(defaults: defaults, loginItemRegistry: registry)

        settings.launchAtLogin = false
        await settings.waitForLoginItemRequestForTesting()
        settings.launchAtLogin = true
        await settings.waitForLoginItemRequestForTesting()

        XCTAssertEqual(registry.unregisterCallCount, 1)
        XCTAssertEqual(registry.registerCallCount, 1)
        XCTAssertTrue(settings.launchAtLogin)
    }

    /// `refreshLaunchAtLoginFromSystem()` (called by `SettingsView` whenever
    /// its "Основное" tab appears) picks up a change made entirely outside
    /// the app — the person removing VoicePaste in System Settings → Login
    /// Items while it keeps running — without a restart and without calling
    /// register/unregister itself.
    func test_refreshFromSystem_picksUpExternalChange_withoutCallingRegistry() throws {
        let defaults = try makeIsolatedDefaults()
        defer { clean(defaults) }
        let registry = FakeLoginItemRegistry(initialStatus: .enabled)
        let settings = AppSettings(defaults: defaults, loginItemRegistry: registry)
        XCTAssertTrue(settings.launchAtLogin)

        // The person removed the entry from outside the app.
        registry.simulateExternalStatusChange(.notRegistered)
        settings.refreshLaunchAtLoginFromSystem()

        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertEqual(registry.registerCallCount, 0)
        XCTAssertEqual(registry.unregisterCallCount, 0)
    }

    /// `ProcessRuntime.isRunningTests` is always true for this suite, so
    /// `AppSettings`'s own default parameter picks `NullLoginItemRegistry`
    /// whenever a test constructs it without an explicit registry — exactly
    /// the guard that keeps `scripts/test-safely.sh` from ever touching the
    /// installed copy's Login Items entry. A toggle against that default
    /// settles back to off because the null registry never reports
    /// `.enabled`.
    func test_testHostDefault_neverReflectsEnabled_regardlessOfToggle() async throws {
        let defaults = try makeIsolatedDefaults()
        defer { clean(defaults) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.launchAtLogin)

        settings.launchAtLogin = true
        await settings.waitForLoginItemRequestForTesting()

        XCTAssertFalse(settings.launchAtLogin)
    }
}

/// Test double for `LoginItemRegistering`: in-memory only, never touches the
/// real Login Items registry. `nonisolated` (mirroring `AppSettings.swift`'s
/// own `LockedBool`) because the project defaults undeclared isolation to
/// `@MainActor`, but `register()`/`unregister()` must run off the main actor
/// — `AppSettings.requestLoginItemChange` dispatches them via
/// `Task.detached` — while assertions read state back on the main actor.
/// `@unchecked Sendable` because every access goes through `lock` instead of
/// actor isolation.
private nonisolated final class FakeLoginItemRegistry: LoginItemRegistering, @unchecked Sendable {
    private let lock = NSLock()
    private var currentStatus: SMAppService.Status

    var registerError: Error?
    var unregisterError: Error?
    /// Status reported once a *successful* `register()` returns. Defaults to
    /// `.enabled`, matching the ordinary case; a test can point it at
    /// `.requiresApproval` to model the "call didn't throw but nothing is
    /// really on yet" case `L-020` explicitly guards against.
    var statusAfterRegister: SMAppService.Status = .enabled
    var statusAfterUnregister: SMAppService.Status = .notRegistered

    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

    init(initialStatus: SMAppService.Status) {
        currentStatus = initialStatus
    }

    var status: SMAppService.Status {
        lock.lock()
        defer { lock.unlock() }
        return currentStatus
    }

    func register() throws {
        lock.lock()
        registerCallCount += 1
        lock.unlock()
        if let registerError {
            throw registerError
        }
        lock.lock()
        currentStatus = statusAfterRegister
        lock.unlock()
    }

    func unregister() throws {
        lock.lock()
        unregisterCallCount += 1
        lock.unlock()
        if let unregisterError {
            throw unregisterError
        }
        lock.lock()
        currentStatus = statusAfterUnregister
        lock.unlock()
    }

    /// A change the test attributes to something *other* than this fake's
    /// own `register()`/`unregister()` — standing in for the person using
    /// System Settings → Login Items directly.
    func simulateExternalStatusChange(_ status: SMAppService.Status) {
        lock.lock()
        currentStatus = status
        lock.unlock()
    }
}
