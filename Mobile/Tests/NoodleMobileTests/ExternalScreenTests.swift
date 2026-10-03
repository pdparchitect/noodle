import HubLink
import SwiftUI
import UIKit
import XCTest

@testable import NoodleMobile

/// A TV reached by Screen Mirroring or a cable shows the game while the phone becomes its controller.
@MainActor final class ExternalScreenTests: XCTestCase {
    /// iOS mirrors the phone to a TV unless the app takes the TV's scene, so Noodle takes it.
    func testATVGetsItsOwnScene() {
        XCTAssertTrue(AppDelegate.configuration(for: .windowExternalDisplayNonInteractive).delegateClass == ExternalSceneDelegate.self)
        XCTAssertNil(AppDelegate.configuration(for: .windowApplication).delegateClass)
    }

    /// Only a game goes to the TV: one with controls, while a TV is there, unless brought back to the phone.
    func testAGameGoesToTheTVWhileOneIsConnected() {
        let screen = ExternalScreen()
        let game = Gamepad(buttons: [Gamepad.Button(key: "space")])
        XCTAssertFalse(screen.plays(game, onPhone: false))
        screen.connected = true
        XCTAssertTrue(screen.plays(game, onPhone: false))
        XCTAssertFalse(screen.plays(game, onPhone: true))
        XCTAssertFalse(screen.plays(nil, onPhone: false))
    }

    /// A game closing as the next one opens must not take the next one off the TV.
    func testAClosingGameLeavesTheTVToTheNextOne() {
        let screen = ExternalScreen()
        let first = UUID(), second = UUID()
        screen.show(first) { Color.red }
        screen.show(second) { Color.blue }
        screen.clear(first)
        XCTAssertEqual(screen.shown?.id, second)
        screen.clear(second)
        XCTAssertNil(screen.shown)
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
