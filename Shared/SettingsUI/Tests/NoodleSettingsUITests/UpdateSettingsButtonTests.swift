import XCTest
@testable import NoodleSettingsUI

final class UpdateSettingsButtonTests: XCTestCase {
    func testTitleOffersTheInstallOnceAnUpdateIsFound() {
        XCTAssertEqual(UpdateSettingsButton.title(availableVersion: nil), "Check for Updates…")
        XCTAssertEqual(UpdateSettingsButton.title(availableVersion: "2.4.0"), "Install Update…")
    }
}
