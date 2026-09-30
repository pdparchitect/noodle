import NoodletRuntime
import UIKit
import XCTest

@testable import NoodleMobile

@MainActor final class NoodletScreenTests: XCTestCase {
    /// A noodlet that asks for one way holds the phone to it while open; any other lets it turn.
    func testANoodletHoldsTheOrientationItAsksFor() {
        XCTAssertEqual(ScreenOrientation.mask(for: .landscape), .landscape)
        XCTAssertEqual(ScreenOrientation.mask(for: .portrait), .portrait)
        XCTAssertEqual(ScreenOrientation.mask(for: .any), .all)
        XCTAssertEqual(ScreenOrientation.mask(for: nil), .all)
    }

    /// A page laid out for a desktop window gets the desktop site, unless it presents itself as an
    /// app, which fits the phone's view.
    func testOnlyADesktopPageGetsTheDesktopSite() {
        var manifest = NoodletManifest(title: "Game")
        XCTAssertEqual(NoodletDeviceScreen.contentMode(for: manifest), .desktop)
        manifest.display = .standalone
        XCTAssertEqual(NoodletDeviceScreen.contentMode(for: manifest), .mobile)
        manifest.display = .browser
        manifest.layout = .adaptive
        XCTAssertEqual(NoodletDeviceScreen.contentMode(for: manifest), .mobile)
    }
}
