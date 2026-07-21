import AppKit
import XCTest
@testable import VoicePaste

/// Gate 2 integration test for `TextInserter` (`L-007`, `INV-008`).
///
/// The `xcodebuild test` runner process is never Accessibility-trusted
/// (`AXIsProcessTrusted()` returns `false` for a plain XCTest bundle with no
/// TCC grant), so every path through `insert(_:into:)` in this environment
/// deterministically takes the "no Accessibility" branch — which is exactly
/// `EC-002`/`AT-003`/`AT-008`'s "honest clipboard fallback" behavior. This
/// gives a real (not mocked) integration test against the actual
/// `NSPasteboard.general` without requiring a granted Accessibility
/// permission or a live target app.
@MainActor
final class TextInserterTests: XCTestCase {

    override func tearDown() {
        NSPasteboard.general.clearContents()
        super.tearDown()
    }

    /// `EC-002`: "Нет Accessibility-разрешения → можно распознать и
    /// скопировать; прямую вставку не обещать."
    func test_EC002_noAccessibilityTrust_fallsBackToClipboard_withNoSnapshot() {
        let inserter = TextInserter()
        let text = "Текст без Accessibility-доступа \(UUID().uuidString)"

        let outcome = inserter.insert(text, into: nil)

        XCTAssertEqual(outcome, .copied)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), text)
    }

    /// `AT-008`/`EC-006`: even with a captured front-app snapshot (as if
    /// recording had started in some app), losing Accessibility trust (or,
    /// as here, never having it) must still copy rather than silently drop
    /// the result or crash trying to reach a stale/foreign process.
    func test_AT008_EC006_withStaleSnapshot_stillFallsBackToClipboard_honestly() {
        let inserter = TextInserter()
        let text = "Готовый текст \(UUID().uuidString)"
        // A snapshot pointing at a pid that is almost certainly not the
        // current frontmost app (and may not exist at all) — simulates the
        // target having closed/lost focus.
        let staleSnapshot = FrontAppSnapshot(bundleIdentifier: "com.example.closed", processIdentifier: 999_999)

        let outcome = inserter.insert(text, into: staleSnapshot)

        XCTAssertEqual(outcome, .copied)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), text)
    }

    func test_captureFrontAppSnapshot_returnsSomethingForRunningTestProcess() {
        // Sanity check that the snapshot API itself doesn't crash/return
        // garbage in a headless test run; the frontmost app while running
        // under `xcodebuild test` is whatever process XCTest hosts as.
        _ = TextInserter.captureFrontAppSnapshot()
        // No assertion beyond "did not crash" — frontmost app identity in a
        // CI/test runner is environment-dependent and not meaningful to pin
        // down further here.
    }

    /// Clipboard fallback must carry the exact final text, never a stale or
    /// partial value from a previous insertion attempt.
    func test_copyToClipboard_overwritesPreviousClipboardContent() {
        let inserter = TextInserter()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("previous content", forType: .string)

        _ = inserter.insert("new content", into: nil)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "new content")
    }

    func test_pasteEligibility_allowsTerminalAndEditorRoles_butRejectsGenericWindow() {
        XCTAssertTrue(TextInserter.isPasteEligibleRole("AXTextArea"))
        XCTAssertTrue(TextInserter.isPasteEligibleRole("AXWebArea"))
        XCTAssertTrue(TextInserter.isPasteEligibleRole("AXTextField"))
        XCTAssertFalse(TextInserter.isPasteEligibleRole("AXWindow"))
        XCTAssertFalse(TextInserter.isPasteEligibleRole("AXGroup"))
        XCTAssertFalse(TextInserter.isPasteEligibleRole("AXButton"))
    }

    /// AT-085: the policy is deliberately stricter than "the app was
    /// frontmost". Any concrete editable AX target is safe, while a generic
    /// focused composer is only allowed for the narrow, tested compatibility
    /// set. This is pure logic so a unit test protects Finder/System Settings
    /// without attempting to synthesize a real paste there.
    func test_AT085_pasteTargetEligibility_requiresVerifiedAXOrKnownOpaqueCompatibilityEditor() {
        XCTAssertEqual(
            TextInserter.pasteTargetEligibility(
                bundleIdentifier: "com.apple.finder",
                hasVerifiedEditableAXTarget: true,
                hasOpaqueFocusedComposer: false
            ),
            .verifiedAXTarget
        )
        XCTAssertEqual(
            TextInserter.pasteTargetEligibility(
                bundleIdentifier: "com.openai.codex",
                hasVerifiedEditableAXTarget: false,
                hasOpaqueFocusedComposer: true
            ),
            .opaqueCompatibilityTarget
        )
        XCTAssertEqual(
            TextInserter.pasteTargetEligibility(
                bundleIdentifier: "ru.keepcoder.Telegram",
                hasVerifiedEditableAXTarget: false,
                hasOpaqueFocusedComposer: true
            ),
            .opaqueCompatibilityTarget
        )
        XCTAssertEqual(
            TextInserter.pasteTargetEligibility(
                bundleIdentifier: "com.apple.finder",
                hasVerifiedEditableAXTarget: false,
                hasOpaqueFocusedComposer: true
            ),
            .clipboardOnly
        )
        XCTAssertEqual(
            TextInserter.pasteTargetEligibility(
                bundleIdentifier: "com.apple.systempreferences",
                hasVerifiedEditableAXTarget: false,
                hasOpaqueFocusedComposer: true
            ),
            .clipboardOnly
        )
        XCTAssertEqual(
            TextInserter.pasteTargetEligibility(
                bundleIdentifier: "com.example.unknown",
                hasVerifiedEditableAXTarget: false,
                hasOpaqueFocusedComposer: true
            ),
            .clipboardOnly
        )
        XCTAssertEqual(
            TextInserter.pasteTargetEligibility(
                bundleIdentifier: "com.openai.codex",
                hasVerifiedEditableAXTarget: false,
                hasOpaqueFocusedComposer: false
            ),
            .clipboardOnly
        )
    }

    func test_officeTargetsUseExtendedPasteboardWindow() {
        let officeBundleIdentifiers = [
            "com.microsoft.Word",
            "com.microsoft.Excel",
            "com.microsoft.Powerpoint",
        ]

        for bundleIdentifier in officeBundleIdentifiers {
            XCTAssertTrue(
                TextInserter.usesExtendedPasteboardWindow(
                    FrontAppSnapshot(bundleIdentifier: bundleIdentifier, processIdentifier: 1)
                ),
                "Expected extended clipboard window for \(bundleIdentifier)"
            )
        }
        XCTAssertFalse(
            TextInserter.usesExtendedPasteboardWindow(
                FrontAppSnapshot(bundleIdentifier: "com.apple.finder", processIdentifier: 1)
            )
        )
    }

    func test_allEligibleTargetsUseTheSameHIDPasteRoute_withoutAutomation() {
        XCTAssertEqual(
            TextInserter.pasteEventRoute(
                for: .init(bundleIdentifier: "com.openai.codex", processIdentifier: 1)
            ),
            .hid
        )
        XCTAssertEqual(
            TextInserter.pasteEventRoute(
                for: .init(bundleIdentifier: "com.anthropic.claudefordesktop", processIdentifier: 1)
            ),
            .hid
        )
        XCTAssertEqual(
            TextInserter.pasteEventRoute(
                for: .init(bundleIdentifier: "com.microsoft.Word", processIdentifier: 1)
            ),
            .hid
        )
    }

    /// `AT-098`: `com.openai.chat` (desktop ChatGPT) is the bundle id this
    /// defect fix targeted directly — pin its policy outcome by name rather
    /// than relying only on the generic compatibility-set loop above, so a
    /// future edit that drops it from `knownOpaqueCompatibilityBundleIdentifiers`
    /// or routes it back through per-app Automation fails a test that names
    /// ChatGPT, not just an unrelated sibling bundle (Codex/Claude). Live
    /// smoke still proves real appearance in the composer; this unit test
    /// protects the no-Automation route selection.
    func test_AT098_chatGPT_isOpaqueCompatibilityTarget_usingHIDRouteAndExtendedWindow() {
        XCTAssertEqual(
            TextInserter.pasteTargetEligibility(
                bundleIdentifier: "com.openai.chat",
                hasVerifiedEditableAXTarget: false,
                hasOpaqueFocusedComposer: true
            ),
            .opaqueCompatibilityTarget
        )
        XCTAssertEqual(
            TextInserter.pasteTargetEligibility(
                bundleIdentifier: "com.openai.chat",
                hasVerifiedEditableAXTarget: false,
                hasOpaqueFocusedComposer: false
            ),
            .clipboardOnly,
            "AT-098/AT-084: ChatGPT without a safe opaque focused composer must still be clipboard-only, not blind-pasted"
        )
        XCTAssertEqual(
            TextInserter.pasteEventRoute(
                for: .init(bundleIdentifier: "com.openai.chat", processIdentifier: 1)
            ),
            .hid
        )
        XCTAssertTrue(
            TextInserter.usesExtendedPasteboardWindow(
                FrontAppSnapshot(bundleIdentifier: "com.openai.chat", processIdentifier: 1)
            ),
            "ChatGPT's Electron composer can read the clipboard asynchronously after the shortcut; must not restore under it"
        )
    }

    // MARK: - L-007 step 2: clipboard snapshot/restore round-trip
    //
    // `pasteViaClipboardAndKeystroke` itself can't be exercised headlessly
    // (it only runs once `AXIsProcessTrusted()` is true, never the case
    // under `xcodebuild test`), but the snapshot/restore halves it's built
    // from are plain pasteboard operations, testable directly.

    func test_snapshotPasteboard_restorePasteboard_roundTripsPlainText() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("original clipboard value", forType: .string)

        let snapshot = TextInserter.snapshotPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("temporary dictation text", forType: .string)
        XCTAssertEqual(pasteboard.string(forType: .string), "temporary dictation text")

        TextInserter.restorePasteboard(snapshot)

        XCTAssertEqual(pasteboard.string(forType: .string), "original clipboard value")
    }

    func test_restorePasteboard_ofEmptySnapshot_leavesClipboardEmpty() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let emptySnapshot = TextInserter.snapshotPasteboard()
        XCTAssertTrue(emptySnapshot.isEmpty)

        pasteboard.setString("should be cleared", forType: .string)
        TextInserter.restorePasteboard(emptySnapshot)

        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func test_snapshotPasteboard_capturesMultipleTypes() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("plain form", forType: .string)
        pasteboard.setString("<b>rich form</b>", forType: .html)

        let snapshot = TextInserter.snapshotPasteboard()
        XCTAssertEqual(snapshot[.string], "plain form".data(using: .utf8))
        XCTAssertNotNil(snapshot[.html])

        pasteboard.clearContents()
        TextInserter.restorePasteboard(snapshot)
        XCTAssertEqual(pasteboard.string(forType: .string), "plain form")
        XCTAssertEqual(pasteboard.string(forType: .html), "<b>rich form</b>")
    }
}
