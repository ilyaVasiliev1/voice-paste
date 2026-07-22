import AppKit
import XCTest
@testable import VoicePaste

/// Unit and integration coverage for the one-route desktop paste policy.
/// XCTest itself has no Universal Access, so outcome tests deterministically
/// exercise the honest clipboard path without touching a real editor.
@MainActor
final class TextInserterTests: XCTestCase {
    override func tearDown() {
        NSPasteboard.general.clearContents()
        super.tearDown()
    }

    func test_EC002_noAccessibilityTrust_keepsExactTextOnClipboard() {
        let text = "Текст без Universal Access \(UUID().uuidString)"

        XCTAssertEqual(TextInserter().insert(text, into: nil), .copied)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), text)
    }

    func test_AT008_changedOrMissingTarget_keepsExactTextOnClipboard() {
        let text = "Готовый текст \(UUID().uuidString)"
        let stale = FrontAppSnapshot(
            bundleIdentifier: "com.example.closed",
            processIdentifier: 999_999
        )

        XCTAssertEqual(TextInserter().insert(text, into: stale), .copied)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), text)
    }

    func test_copyToClipboard_replacesPreviousClipboardContent() {
        NSPasteboard.general.setString("previous", forType: .string)

        TextInserter.copyToClipboard("new")

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "new")
    }

    func test_AT084_everyExternalTextApplicationUsesTheSameHIDRoute() {
        let bundles = [
            "com.openai.chat", "com.microsoft.Word", "ru.keepcoder.Telegram",
            "com.apple.Terminal", "com.microsoft.VSCode", "com.apple.Notes",
            "com.apple.Safari", "com.google.Chrome",
        ]

        for bundle in bundles {
            XCTAssertEqual(
                TextInserter.pasteTargetEligibility(bundleIdentifier: bundle),
                .capturedApplication,
                "Expected universal HID paste for \(bundle)"
            )
        }
    }

    func test_AT084_HIDPasteUsesACompleteModifierAndVKeySequence() {
        XCTAssertEqual(
            TextInserter.standardHIDPasteSequence,
            [.commandDown, .vDown, .vUp, .commandUp]
        )
        XCTAssertEqual(TextInserter.standardHIDPasteSequence.map(\.virtualKey), [55, 9, 9, 55])
        XCTAssertEqual(TextInserter.standardHIDPasteSequence.map(\.isKeyDown), [true, true, false, false])
    }

    func test_AT055_nonTextDestinationsRemainClipboardOnly() {
        for bundle in [
            "com.apple.finder",
            "com.apple.systempreferences",
            "com.apple.systemsettings",
            "com.ilyavasiliev.voicepaste",
            nil,
        ] as [String?] {
            XCTAssertEqual(
                TextInserter.pasteTargetEligibility(bundleIdentifier: bundle),
                .clipboardOnly
            )
        }
    }
}
