import XCTest

@testable import VoicePaste

/// Требование «Состояние модели отрисовано одним видом в настройках и
/// онбординге»: признак «модель на диске» один на оба экрана.
@MainActor
final class ModelStateInstalledTests: XCTestCase {

    func test_installed_onlyWhenModelIsOnDisk() {
        let progress = ModelDownloadProgress(completedBytes: 1, totalBytes: 2, fraction: 0.5)

        XCTAssertTrue(ModelState.ready.isInstalled)
        XCTAssertTrue(ModelState.unloaded.isInstalled)
        XCTAssertTrue(ModelState.preparing.isInstalled, "подготовка — это модель с диска, не загрузка")

        XCTAssertFalse(ModelState.notPrepared.isInstalled)
        XCTAssertFalse(ModelState.downloading(progress).isInstalled)
        XCTAssertFalse(ModelState.verifying.isInstalled)
        XCTAssertFalse(ModelState.failed(.downloadFailed).isInstalled)
    }
}
