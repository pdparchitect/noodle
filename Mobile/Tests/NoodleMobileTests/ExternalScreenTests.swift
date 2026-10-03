import HubLink
import UIKit
import XCTest

@testable import NoodleMobile

/// A TV reached by Screen Mirroring or a cable shows the game while the phone becomes its controller.
@MainActor final class ExternalScreenTests: XCTestCase {
    /// Only a game goes to the TV: one with controls, while iOS has a TV for it, unless brought back to the phone.
    func testAGameGoesToTheTVWhileOneIsAvailable() {
        let game = Gamepad(buttons: [Gamepad.Button(key: "space")])
        XCTAssertFalse(ExternalScreen.plays(game, available: false, onPhone: false))
        XCTAssertTrue(ExternalScreen.plays(game, available: true, onPhone: false))
        XCTAssertFalse(ExternalScreen.plays(game, available: true, onPhone: true))
        XCTAssertFalse(ExternalScreen.plays(nil, available: true, onPhone: false))
    }

    /// A page is one view, so the screen that shows it last holds it, and the one it left
    /// going away does not take it along.
    func testAPageMovedToTheTVStaysWhenThePhoneLetsGo() {
        let page = UIView()
        let phone = MovableView.Holder(), tv = MovableView.Holder()
        let phoneWindow = UIView()
        phoneWindow.addSubview(phone)
        phone.hold(page)
        XCTAssertTrue(page.superview === phone)

        tv.hold(page)
        phone.removeFromSuperview()
        XCTAssertTrue(page.superview === tv)
        tv.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        tv.layoutIfNeeded()
        XCTAssertEqual(page.frame, tv.bounds)
    }
}
