import XCTest
@testable import VoicePaste

/// Regression guard for the single most destructive bug this app has had:
/// a *network* failure while loading an already-downloaded model was read as
/// "локальная модель битая", and the app deleted the user's 626 MB model and
/// dropped into a re-download that, on the network where the failure happened
/// in the first place, could not succeed.
///
/// Observed in the shipped diagnostic log, repeatedly:
///
///     model.load.failed RetriableDownloadFailure()
///     model.local.invalid
///     model.redownload
///
/// `ModelManager.indicatesUnreadableLocalModel` is the gate that now stands
/// between a load error and `rm -rf`. It must fail *closed*: anything it does
/// not positively recognise as unreadable-on-disk keeps the model.
final class ModelLoadFailureClassificationTests: XCTestCase {

    private struct RetriableDownloadFailure: Error {}
    private struct InvalidMetadataError: Error {
        let message = "File metadata must have been retrieved from server"
    }

    // MARK: - Never delete on a transport problem

    func test_retriableDownloadFailure_doesNotJustifyDeletingTheModel() {
        XCTAssertFalse(ModelManager.indicatesUnreadableLocalModel(RetriableDownloadFailure()))
    }

    func test_urlErrorTimeout_doesNotJustifyDeletingTheModel() {
        XCTAssertFalse(ModelManager.indicatesUnreadableLocalModel(URLError(.timedOut)))
    }

    func test_urlErrorNotConnected_doesNotJustifyDeletingTheModel() {
        XCTAssertFalse(ModelManager.indicatesUnreadableLocalModel(URLError(.notConnectedToInternet)))
    }

    func test_nsurlDomainError_doesNotJustifyDeletingTheModel() {
        let error = NSError(domain: NSURLErrorDomain, code: -1001, userInfo: [
            NSLocalizedDescriptionKey: "Превышен лимит времени на запрос."
        ])
        XCTAssertFalse(ModelManager.indicatesUnreadableLocalModel(error))
    }

    func test_hubMetadataError_doesNotJustifyDeletingTheModel() {
        XCTAssertFalse(ModelManager.indicatesUnreadableLocalModel(InvalidMetadataError()))
    }

    // MARK: - Never delete on cancellation or an unknown error

    func test_cancellation_doesNotJustifyDeletingTheModel() {
        XCTAssertFalse(ModelManager.indicatesUnreadableLocalModel(CancellationError()))
    }

    /// The fail-closed contract: an error nobody has classified must keep the
    /// user's model, not gamble it on a re-download.
    func test_unknownError_failsClosed_andKeepsTheModel() {
        struct SomethingNew: Error {}
        XCTAssertFalse(ModelManager.indicatesUnreadableLocalModel(SomethingNew()))
    }

    // MARK: - Delete only when the files themselves are unreadable

    func test_coreMLMILReadFailure_justifiesDeletingTheModel() {
        let error = NSError(domain: "com.apple.CoreML", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Error in reading the MIL network."
        ])
        XCTAssertTrue(ModelManager.indicatesUnreadableLocalModel(error))
    }

    func test_corruptModelMil_justifiesDeletingTheModel() {
        XCTAssertTrue(
            ModelManager.indicatesUnreadableLocalModel(TranscribingError.underlying("corrupt model.mil"))
        )
    }

    func test_unparsableMLProgram_justifiesDeletingTheModel() {
        let message = "Failed to parse ML Program: model.mil cannot be read"
        XCTAssertTrue(ModelManager.indicatesUnreadableLocalModel(TranscribingError.underlying(message)))
    }

    /// A message that mentions both a transport failure and a model file is
    /// read as a network problem — the safe direction.
    func test_mixedNetworkAndModelWording_isTreatedAsNetwork() {
        let message = "connection lost while reading model.mil"
        XCTAssertFalse(ModelManager.indicatesUnreadableLocalModel(TranscribingError.underlying(message)))
    }
}
