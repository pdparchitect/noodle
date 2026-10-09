import GameController
import HubLink
import NoodletRuntime
import Surface
import UIKit
import WebKit
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

/// The controller's View button shows the conversation's noodlets over a game on the TV.
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

/// The View button opens the menu over any noodlet, on the TV or on the phone.
@MainActor final class GameMenuTests: XCTestCase {
    func testTheViewButtonOpensTheMenuWithoutATV() {
        let first = LinkAttachment(id: UUID(), filename: "Racer.noodlet", mediaType: "application/x-noodlet", byteCount: 0)
        let second = LinkAttachment(id: UUID(), filename: "Tetris.noodlet", mediaType: "application/x-noodlet", byteCount: 0)
        let menu = NoodletMenu(choices: [first, second], current: first.id)
        let hardware = HardwareGamepad(), gameMenu = GameMenu()
        gameMenu.follow(hardware: hardware, menu: { menu }, close: {})

        hardware.onView?()
        XCTAssertEqual(gameMenu.selected, 0)
        hardware.menu?(.right)
        XCTAssertEqual(gameMenu.selected, 1)
        hardware.menu?(.back)
        XCTAssertNil(gameMenu.selected)
        XCTAssertNil(hardware.menu)
    }
}

/// What the menu shows, and the phone staying awake through a game.
@MainActor final class NoodletPlayerTests: XCTestCase {
    /// Shared links carry no card; the menu shows each one's picture and name once fetched.
    func testTheMenuShowsTheFetchedCards() {
        let bare = LinkAttachment(id: UUID(), filename: "Noodlet.noodlet", mediaType: "application/x-noodlet", byteCount: 0)
        var fetched = bare
        fetched.card = LinkCardInfo(title: "Liverpool Street", image: Data([1]))
        let other = LinkAttachment(id: UUID(), filename: "Other.noodlet", mediaType: "application/x-noodlet", byteCount: 0)
        let shown = NoodletPlayer.shown([bare, other], fetched: [bare.id: fetched])
        XCTAssertEqual(shown.map(\.liveTitle), ["Liverpool Street", "Other"])
    }

    /// Controller presses are not touches, so iOS would dim and lock the phone mid-game.
    func testAGameWithAControllerOrOnTheTVKeepsThePhoneAwake() {
        XCTAssertFalse(NoodletPlayer.keepsAwake(onTV: false, controllerConnected: false))
        XCTAssertTrue(NoodletPlayer.keepsAwake(onTV: true, controllerConnected: false))
        XCTAssertTrue(NoodletPlayer.keepsAwake(onTV: false, controllerConnected: true))
    }
}

/// WebKit gives a page controllers only while it is the first responder, which a page on the TV
/// never is, so the phone lends it the controllers in hand as Gamepad API pads.
@MainActor final class LentGamepadTests: XCTestCase {
    /// A controller reads as a standard pad: sticks with down positive, every button by position,
    /// except View, which opens Noodle's menu.
    func testAControllerReadsAsAStandardPad() throws {
        let controller = GCController.withExtendedGamepad()
        let full = try XCTUnwrap(controller.extendedGamepad)
        full.buttonA.setValue(1)
        full.rightTrigger.setValue(0.5)
        full.dpad.setValueForXAxis(-1, yAxis: 0)
        full.leftThumbstick.setValueForXAxis(0.25, yAxis: 1)
        full.buttonOptions?.setValue(1)

        let pads = LentGamepads.pads([controller, GCController.withMicroGamepad()], playing: true)
        XCTAssertEqual(pads.count, 1)
        let pad = pads[0]
        XCTAssertEqual(pad.buttons.count, 17)
        XCTAssertEqual(pad.buttons[0], 1)
        XCTAssertEqual(pad.buttons[7], 0.5)
        XCTAssertEqual(pad.buttons[14], 1)
        XCTAssertEqual(pad.buttons[8], 0)
        XCTAssertEqual(pad.axes, [0.25, -1, 0, 0])

        // While Noodle's menu is open the pad stays, let go.
        let paused = LentGamepads.pads([controller], playing: false)
        XCTAssertEqual(paused.count, 1)
        XCTAssertEqual(paused[0].buttons, Array(repeating: 0, count: 17))
        XCTAssertEqual(paused[0].axes, [0, 0, 0, 0])
    }

    /// A page lent pads reads them from `getGamepads()` as real ones and hears them come and go;
    /// a pad it kept from the event follows the controller.
    func testAPageReadsTheLentPads() async throws {
        let configuration = WKWebViewConfiguration()
        NoodletDeviceScreen.configure(configuration, for: NoodletManifest(title: "Game"))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        web.loadHTMLString("""
            <script>
            var heard = [], kept = null;
            addEventListener('gamepadconnected', e => { heard.push('+' + e.gamepad.index); kept = e.gamepad; });
            addEventListener('gamepaddisconnected', e => heard.push('-' + e.gamepad.index));
            </script>
            """, baseURL: nil)
        for _ in 0..<100 where web.isLoading || web.url == nil { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(200))

        var pad = LentGamepads.Pad(id: "Xbox Wireless Controller", buttons: Array(repeating: 0, count: 17), axes: [0, 0, 0, 0])
        pad.buttons[0] = 1
        _ = try await web.evaluateJavaScript(LentGamepads.script([pad]))
        let read = try await web.evaluateJavaScript("""
            (() => { const p = navigator.getGamepads().filter(Boolean);
              return [p.length, p[0].id, p[0].mapping, p[0].connected, p[0].buttons[0].pressed, p[0].buttons[1].pressed,
                      p[0] instanceof Gamepad, p[0].buttons[0] instanceof GamepadButton, p[0] === kept].join(); })()
            """) as? String
        XCTAssertEqual(read, "1,Xbox Wireless Controller,standard,true,true,false,true,true,true")

        pad.buttons[0] = 0
        pad.axes[0] = 1
        _ = try await web.evaluateJavaScript(LentGamepads.script([pad]))
        let kept = try await web.evaluateJavaScript("[kept.buttons[0].pressed, kept.axes[0]].join()") as? String
        XCTAssertEqual(kept, "false,1")

        _ = try await web.evaluateJavaScript(LentGamepads.script(nil))
        let gone = try await web.evaluateJavaScript("[navigator.getGamepads().filter(Boolean).length, heard.join(' ')].join()") as? String
        XCTAssertEqual(gone, "0,+0 -0")
    }
}
