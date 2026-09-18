import Sparkle
import XCTest
@testable import NoodleComputer

@MainActor final class ComputerUpdaterTests: XCTestCase {
    /// Sparkle's delegate methods are optional, so a mismatched signature would
    /// compile and never be called.
    func testUpdaterAnswersSparklesUpdateFoundAndNotFoundCallbacks() {
        let updater = ComputerUpdater()
        XCTAssertTrue(updater.responds(to: #selector(SPUUpdaterDelegate.updater(_:didFindValidUpdate:))))
        XCTAssertTrue(updater.responds(to: #selector(SPUUpdaterDelegate.updaterDidNotFindUpdate(_:error:))))
    }

    func testProbingBeforeTheUpdaterStartsDoesNothing() {
        let updater = ComputerUpdater()
        updater.probeForUpdate()
        XCTAssertNil(updater.availableVersion)
    }
}
