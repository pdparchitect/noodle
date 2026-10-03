import GameController
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

/// While the TV shows the game and a controller covers every button, the phone lists the controllers.
@MainActor final class ConnectedControllerTests: XCTestCase {
    func testAControllerIsShownByItsMakersLogo() {
        XCTAssertEqual(ConnectedController.symbol(for: GCProductCategoryXboxOne), "logo.xbox")
        XCTAssertEqual(ConnectedController.symbol(for: GCProductCategoryDualSense), "logo.playstation")
        XCTAssertEqual(ConnectedController.symbol(for: GCProductCategoryDualShock4), "logo.playstation")
        XCTAssertEqual(ConnectedController.symbol(for: "Switch Pro Controller"), "gamecontroller.fill")
    }

    func testABatteryShowsAsTheNearestQuarter() {
        XCTAssertEqual(ConnectedController.batterySymbol(level: 0.9, charging: false), "battery.100percent")
        XCTAssertEqual(ConnectedController.batterySymbol(level: 0.6, charging: false), "battery.50percent")
        XCTAssertEqual(ConnectedController.batterySymbol(level: 0.05, charging: false), "battery.0percent")
        XCTAssertEqual(ConnectedController.batterySymbol(level: 0.4, charging: true), "battery.100percent.bolt")
    }

    func testOnlyGameControllersAreListed() {
        let pad = GCController.withExtendedGamepad()
        let listed = ConnectedController.list([pad])
        XCTAssertEqual(listed.count, 1)
        XCTAssertFalse(listed[0].name.isEmpty)
        XCTAssertTrue(ConnectedController.list([GCController.withMicroGamepad()]).isEmpty)
    }
}

/// The controller's home button shows the conversation's noodlets over a game on the TV.
@MainActor final class NoodletMenuTests: XCTestCase {
    private func noodlet(_ name: String) -> LinkAttachment {
        LinkAttachment(id: UUID(), filename: "\(name).noodlet", mediaType: "application/x-noodlet", byteCount: 0,
                       url: URL(string: "noodlet://\(UUID().uuidString)"))
    }

    func testTheMenuMovesAlongTheNoodletsThenCloseGame() {
        let first = noodlet("Racer"), second = noodlet("Tetris")
        let menu = NoodletMenu(choices: [first, second], current: first.id)
        XCTAssertEqual(menu.items.count, 3)
        XCTAssertEqual(menu.start, 0)
        XCTAssertEqual(menu.respond(to: .right, at: 0), .move(1))
        XCTAssertEqual(menu.respond(to: .right, at: 2), .move(2))
        XCTAssertEqual(menu.respond(to: .left, at: 0), .move(0))
    }

    func testChoosingSwitchesGamesResumesOrCloses() {
        let first = noodlet("Racer"), second = noodlet("Tetris")
        let menu = NoodletMenu(choices: [first, second], current: first.id)
        XCTAssertEqual(menu.respond(to: .choose, at: 0), .resume)
        XCTAssertEqual(menu.respond(to: .choose, at: 1), .open(second))
        XCTAssertEqual(menu.respond(to: .choose, at: 2), .closeGame)
        XCTAssertEqual(menu.respond(to: .back, at: 1), .resume)
    }
}
