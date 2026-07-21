import XCTest
@testable import VoicePaste

/// `AT-095`/`L-002`/`L-005`: the decoding plan derived from `TranscriptionLanguage`
/// must never request translation, and must only enable language auto-detection
/// (leaving `languageCode` unset) for `.auto` — `.ru`/`.en` force their language
/// explicitly. This is the deterministic slice of AT-095 coverable without
/// linking WhisperKit or running real audio through the model.
@MainActor
final class WhisperDecodingPlanTests: XCTestCase {
    func test_autoDetectsLanguageAndNeverTranslates() {
        let plan = WhisperKitTranscriber.decodingPlan(for: .auto)

        XCTAssertEqual(
            plan,
            WhisperDecodingPlan(
                languageCode: nil,
                detectLanguage: true,
                usePrefillPrompt: true,
                isTranslate: false
            )
        )
    }

    func test_ruForcesLanguageAndNeverTranslates() {
        let plan = WhisperKitTranscriber.decodingPlan(for: .ru)

        XCTAssertEqual(
            plan,
            WhisperDecodingPlan(
                languageCode: "ru",
                detectLanguage: false,
                usePrefillPrompt: true,
                isTranslate: false
            )
        )
    }

    func test_enForcesLanguageAndNeverTranslates() {
        let plan = WhisperKitTranscriber.decodingPlan(for: .en)

        XCTAssertEqual(
            plan,
            WhisperDecodingPlan(
                languageCode: "en",
                detectLanguage: false,
                usePrefillPrompt: true,
                isTranslate: false
            )
        )
    }

    /// Invariant across every mode: the task is always transcription, never
    /// translation (`L-005`) — guards against a future regression that flips
    /// `isTranslate` for any `TranscriptionLanguage` case.
    func test_isTranslateIsAlwaysFalseAcrossAllLanguages() {
        for language in TranscriptionLanguage.allCases {
            let plan = WhisperKitTranscriber.decodingPlan(for: language)
            XCTAssertFalse(plan.isTranslate, "isTranslate must be false for \(language)")
            XCTAssertTrue(plan.usePrefillPrompt, "usePrefillPrompt must be true for \(language)")
        }
    }
}
