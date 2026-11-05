import ComputerBridge
import Sparkle
import XCTest
@testable import ComputerEngine
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

    func testUpdateCheckURLStaysInItsBuildChannel() {
        XCTAssertEqual(ComputerLaunch.updateCheckURL(for: .production).absoluteString, "noodlecomputer://updates/check")
        XCTAssertEqual(ComputerLaunch.updateCheckURL(for: .development).absoluteString, "noodlecomputer-dev://updates/check")
        XCTAssertEqual(ComputerLaunch.updateCheckURL(for: .testing).absoluteString, "noodlecomputer-tests://updates/check")
    }

    /// Sandboxed callers lose launch arguments, so a quiet start must arrive as a URL
    /// that the app takes as its own and that keeps the library closed.
    func testBackgroundURLStartsQuietlyWithoutOpeningTheLibrary() {
        XCTAssertEqual(ComputerLaunch.backgroundURL(for: .production).absoluteString, "noodlecomputer://provider/start")
        XCTAssertEqual(ComputerLaunch.backgroundURL(for: .testing).absoluteString, "noodlecomputer-tests://provider/start")
        let delegate = ComputerAppDelegate()
        XCTAssertFalse(delegate.openedDocument)
        delegate.application(NSApplication.shared, open: [ComputerLaunch.backgroundURL()])
        XCTAssertTrue(delegate.openedDocument)
    }
}
