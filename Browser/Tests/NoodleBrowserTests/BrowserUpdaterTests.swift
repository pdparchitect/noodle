import Sparkle
import XCTest
@testable import NoodleBrowser

@MainActor final class BrowserUpdaterTests: XCTestCase {
    /// Sparkle's delegate methods are optional, so a mismatched signature would
    /// compile and never be called.
    func testUpdaterAnswersSparklesUpdateFoundAndNotFoundCallbacks() {
        let updater = BrowserUpdater()
        XCTAssertTrue(updater.responds(to: #selector(SPUUpdaterDelegate.updater(_:didFindValidUpdate:))))
        XCTAssertTrue(updater.responds(to: #selector(SPUUpdaterDelegate.updaterDidNotFindUpdate(_:error:))))
    }

    func testProbingBeforeTheUpdaterStartsDoesNothing() {
        let updater = BrowserUpdater()
        updater.probeForUpdate()
        XCTAssertNil(updater.availableVersion)
    }
}
