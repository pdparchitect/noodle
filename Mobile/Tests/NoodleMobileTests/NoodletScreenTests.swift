import AVFAudio
import NoodletRuntime
import UIKit
import WebKit
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

    /// A game played from the on-screen controls never gets a tap on its page, so its sound must
    /// start without one.
    func testANoodletPlaysSoundWithoutATapOnItsPage() {
        let configuration = WKWebViewConfiguration()
        NoodletDeviceScreen.configure(configuration, for: NoodletManifest(title: "Game"))
        XCTAssertEqual(configuration.mediaTypesRequiringUserActionForPlayback, [])
    }

    /// WebKit gives a page's Web Audio a category that Silent Mode mutes; a noodlet asks for
    /// playback, as a video app does, so a game is heard either way.
    func testANoodletIsHeardInSilentMode() {
        let configuration = WKWebViewConfiguration()
        NoodletDeviceScreen.configure(configuration, for: NoodletManifest(title: "Game"))
        XCTAssertTrue(configuration.userContentController.userScripts.contains {
            $0.source.contains("navigator.audioSession.type = 'playback'") && $0.injectionTime == .atDocumentStart
        })
    }

    /// While a noodlet is open its sound plays with the ring switch set to silent, alongside what
    /// else is playing; afterwards the app goes back to the switch.
    func testANoodletIsHeardWithTheRingSwitchSilent() {
        let session = AVAudioSession.sharedInstance()
        NoodletSound.start()
        XCTAssertEqual(session.category, .playback)
        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers))
        NoodletSound.stop()
        XCTAssertEqual(session.category, .soloAmbient)
    }
}
