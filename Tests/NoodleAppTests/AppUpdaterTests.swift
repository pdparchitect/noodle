import Sparkle
import XCTest
@testable import Noodle

@MainActor final class AppUpdaterTests: XCTestCase {
    /// Sparkle's delegate methods are optional, so a mismatched signature would
    /// compile and never be called.
    func testUpdaterAnswersSparklesUpdateFoundAndNotFoundCallbacks() {
        let updater = AppUpdater()
        XCTAssertTrue(updater.responds(to: #selector(SPUUpdaterDelegate.updater(_:didFindValidUpdate:))))
        XCTAssertTrue(updater.responds(to: #selector(SPUUpdaterDelegate.updaterDidNotFindUpdate(_:error:))))
    }

    func testProbingBeforeTheUpdaterStartsDoesNothing() {
        let updater = AppUpdater()
        updater.probeForUpdate()
        XCTAssertNil(updater.availableVersion)
    }
}
