import AppletCore
import AppKit
import WebKit
import XCTest

@testable import NoodleApplet

/// A noodlet watched from another device draws in a window the Mac does not show. macOS takes
/// such a page for idle a minute or so after the window last changed, and WebKit then halves its
/// animation frames and lets it nap, so a game watched from a phone turns choppy.
final class WatchedTests: XCTestCase {
    @MainActor private func makeRunner() throws -> (WebRunner, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let package = try NoodletPackage.install([
            "noodlet.json": Data(#"{"version":1,"title":"Game","runtime":"html","entry":"index.html"}"#.utf8),
            "index.html": Data("<title>Game</title>".utf8),
        ], to: root.appendingPathComponent("Game.noodlet"))
        let runner = WebRunner(
            package: package, dataRoot: root, log: AppletLog(url: root.appendingPathComponent("log.txt")),
            size: CGSize(width: 320, height: 240), storeID: UUID(), rememberFrame: false)
        return (runner, root)
    }

    /// WebKit's own setting, so the test pins what the page gets and not a flag Applet keeps.
    @MainActor private func mayNap(_ runner: WebRunner) -> Bool? {
        (runner.web.configuration.preferences.value(forKey: "_appNapEnabled") as? NSNumber)?.boolValue
    }

    @MainActor func testAWatchedNoodletIsNeverNapped() async throws {
        let (runner, root) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: root) }
        try await runner.start()
        defer { runner.stop() }
        XCTAssertEqual(mayNap(runner), true, "an unwatched background noodlet should save energy as any page does")
        runner.watched = true
        XCTAssertEqual(mayNap(runner), false, "a watched noodlet may nap and stutter on the viewer's screen")
        runner.watched = false
        XCTAssertEqual(mayNap(runner), true)
    }

    @MainActor func testAWatchedNoodletKeepsItsWindowChanging() async throws {
        let (runner, root) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: root) }
        runner.stillAfter = .milliseconds(50)
        try await runner.start()
        defer { runner.stop() }
        runner.watched = true
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertGreaterThanOrEqual(runner.stirred, 2, "the unseen window was left to go idle")
        XCTAssertTrue(runner.window.isVisible && runner.window.alphaValue == 0, "stirring left the window off screen or visible")
        runner.watched = false
        let stirred = runner.stirred
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(runner.stirred, stirred, "a window nobody watches was still stirred")
    }

    /// A window on the Mac's screen changes whenever the person uses it, so it is left alone.
    @MainActor func testANoodletShownOnTheMacIsNotStirred() async throws {
        let (runner, root) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: root) }
        runner.stillAfter = .milliseconds(50)
        try await runner.start()
        defer { runner.stop() }
        runner.watched = true
        runner.show()
        let stirred = runner.stirred
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(runner.stirred, stirred)
        XCTAssertEqual(mayNap(runner), true)
    }
}
