import XCTest
@testable import VoicePaste

/// `AT-093`/`L-010` — storage half of the model-download-source setting.
/// Proof mode `auto`: pure `AppSettings` + isolated `UserDefaults`, no
/// network, no WhisperKit, no real download.
@MainActor
final class AppSettingsModelDownloadSourceTests: XCTestCase {

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "AppSettingsModelDownloadSourceTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }

    private func clean(_ defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
    }

    /// `AT-093`/`L-010`: the default source is `.github` — the only host
    /// reachable from mainland China (where the app is used), so a fresh
    /// install downloads the model successfully out of the box instead of
    /// stalling against HuggingFace/its mirror.
    func test_default_isGitHub_onEmptyDefaults() {
        let defaults = makeIsolatedDefaults()
        defer { clean(defaults) }

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.modelDownloadSource, .github)
    }

    /// `AT-093`: "Значение сохраняется между запусками" — setting `.official`
    /// then constructing a *new* `AppSettings` instance against the same
    /// `UserDefaults` suite (simulating a relaunch) must still read
    /// `.official` back, proving persistence rather than in-memory state.
    func test_settingOfficial_persistsAcrossNewAppSettingsInstance() {
        let defaults = makeIsolatedDefaults()
        defer { clean(defaults) }

        let firstRun = AppSettings(defaults: defaults)
        firstRun.modelDownloadSource = .official

        let secondRun = AppSettings(defaults: defaults)

        XCTAssertEqual(secondRun.modelDownloadSource, .official)
        XCTAssertEqual(secondRun.modelDownloadEndpoint, "https://huggingface.co")
    }

    /// Round-trip back to the default after an explicit re-selection —
    /// guards against a persistence bug that could only ever move one way.
    func test_settingBackToMirror_persistsAcrossNewAppSettingsInstance() {
        let defaults = makeIsolatedDefaults()
        defer { clean(defaults) }

        let firstRun = AppSettings(defaults: defaults)
        firstRun.modelDownloadSource = .official
        firstRun.modelDownloadSource = .mirror

        let secondRun = AppSettings(defaults: defaults)

        XCTAssertEqual(secondRun.modelDownloadSource, .mirror)
    }

    /// A raw defaults value that doesn't match any known case (e.g. a stale
    /// build's removed case, or corrupted defaults) must fall back to the
    /// documented default rather than crash or silently pick `.official`.
    func test_unrecognizedStoredValue_fallsBackToGitHub() {
        let defaults = makeIsolatedDefaults()
        defer { clean(defaults) }
        defaults.set("some-removed-case", forKey: "modelDownloadSource")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.modelDownloadSource, .github)
    }
}
