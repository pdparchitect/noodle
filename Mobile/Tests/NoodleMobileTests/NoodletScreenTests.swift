import AVFAudio
import NoodletRuntime
import Surface
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

    /// A game draws no more pixels than a handheld console on the phone, or a docked one on a TV,
    /// and is scaled up to fill; a page that is not a game keeps the screen's sharpness.
    func testAGameDrawsAtConsoleResolution() async throws {
        var game = NoodletManifest(title: "Game")
        game.controls = Gamepad(buttons: [Gamepad.Button(key: "space")])
        let web = try await page(for: game, size: CGSize(width: 852, height: 393))
        let phone = try await drawn(web)
        XCTAssertLessThanOrEqual(phone.long, 1280)
        XCTAssertLessThanOrEqual(phone.short, 720)
        XCTAssertGreaterThan(phone.long, 1200)

        _ = try await web.evaluateJavaScript(NoodletDeviceScreen.renderSize(onTV: true))
        web.frame.size = CGSize(width: 3840, height: 2160)
        web.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let tv = try await drawn(web)
        XCTAssertLessThanOrEqual(tv.long, 1920)
        XCTAssertGreaterThan(tv.long, 1800)

        let app = try await page(for: NoodletManifest(title: "App"), size: CGSize(width: 852, height: 393))
        let ratio = try await app.evaluateJavaScript("devicePixelRatio") as? Double
        XCTAssertEqual(ratio, Double(UIScreen.main.scale))
    }

    private var windows: [UIWindow] = []

    private func page(for manifest: NoodletManifest, size: CGSize) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        NoodletDeviceScreen.configure(configuration, for: manifest)
        let web = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: configuration)
        let window = UIWindow(frame: web.frame)
        window.addSubview(web)
        window.isHidden = false
        windows.append(window)
        web.loadHTMLString("<meta name=viewport content='width=device-width, initial-scale=1'><body></body>", baseURL: nil)
        for _ in 0..<100 where web.isLoading || web.url == nil { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(200))
        return web
    }

    /// The pixels a canvas sized as games size theirs would hold: its page's size times devicePixelRatio.
    private func drawn(_ web: WKWebView) async throws -> (long: Double, short: Double) {
        let size = try await web.evaluateJavaScript("[innerWidth * devicePixelRatio, innerHeight * devicePixelRatio]") as? [Double]
        let pixels = try XCTUnwrap(size)
        return (pixels.max()!, pixels.min()!)
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
