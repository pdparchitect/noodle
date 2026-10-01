import AppKit
import XCTest
@testable import Noodle
@testable import NoodleRuntimeSettings

@MainActor final class CompanionAppCommandsTests: XCTestCase {
    func testOnlyInstalledCompanionsAreAvailable() throws {
        let url = FileManager.default.temporaryDirectory
        let installation = try XCTUnwrap(CompanionAppInstallation(applicationURL: url))
        let menu = CompanionAppMenu(discover: { [.browser: installation] })

        XCTAssertTrue(menu.isAvailable(.browser))
        XCTAssertFalse(menu.isAvailable(.computer))
        XCTAssertFalse(menu.isAvailable(.applet))
    }

    func testRefreshesWhenNoodleBecomesActive() throws {
        let url = FileManager.default.temporaryDirectory
        let installation = try XCTUnwrap(CompanionAppInstallation(applicationURL: url))
        var installed: [CompanionApp: CompanionAppInstallation] = [:]
        let center = NotificationCenter()
        let menu = CompanionAppMenu(discover: { installed }, notificationCenter: center)
        XCTAssertFalse(menu.isAvailable(.applet))

        installed[.applet] = installation
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        XCTAssertTrue(menu.isAvailable(.applet))
    }
}
