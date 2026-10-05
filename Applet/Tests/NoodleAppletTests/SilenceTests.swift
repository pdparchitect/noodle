import AppletCore
import WebKit
import XCTest

@testable import NoodleApplet

/// A noodlet the user cannot see must not be heard.
final class SilenceTests: XCTestCase {
    @MainActor private func makeRunner(foreground: Bool = false) throws -> (WebRunner, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let package = try NoodletPackage.install([
            "noodlet.json": Data(#"{"version":1,"title":"Noisy","runtime":"html","entry":"index.html"}"#.utf8),
            "index.html": Data("<title>Noisy</title>".utf8),
        ], to: root.appendingPathComponent("Noisy.noodlet"))
        let dataRoot = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        let runner = WebRunner(
            package: package, dataRoot: dataRoot, log: AppletLog(url: root.appendingPathComponent("log.txt")),
            size: CGSize(width: 320, height: 240), storeID: UUID(), foreground: foreground, rememberFrame: false)
        return (runner, root)
    }

    /// WebKit's own muted state, so the test pins the silence and not a flag Applet keeps.
    @MainActor private func webKitMutedAudio(_ runner: WebRunner) -> Bool {
        ((runner.web.value(forKey: "mediaMutedState") as? NSNumber)?.uintValue ?? 0) & 1 == 1
    }

    @MainActor func testABackgroundNoodletStartsMuted() async throws {
        let (runner, root) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: root) }
        try await runner.start()
        defer { runner.stop() }
        XCTAssertTrue(runner.muted)
        XCTAssertTrue(webKitMutedAudio(runner))
    }

    /// WebKit's mute leaves speech synthesis audible, so a noodlet started out of sight has none.
    @MainActor func testABackgroundNoodletCannotSpeak() async throws {
        let (runner, root) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: root) }
        try await runner.start()
        defer { runner.stop() }
        let speech = try await runner.evaluate("return typeof speechSynthesis")
        XCTAssertEqual(speech, #""undefined""#)
    }

    @MainActor func testANoodletThePersonOpensCanSpeak() async throws {
        let (runner, root) = try makeRunner(foreground: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await runner.start()
        defer { runner.stop() }
        let speech = try await runner.evaluate("return typeof speechSynthesis")
        XCTAssertEqual(speech, #""object""#)
    }

    @MainActor func testSoundFollowsTheWindow() async throws {
        let (runner, root) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: root) }
        try await runner.start()
        defer { runner.stop() }
        runner.show()
        XCTAssertFalse(runner.muted)
        XCTAssertFalse(webKitMutedAudio(runner))
        runner.hide()
        XCTAssertTrue(runner.muted)
        XCTAssertTrue(webKitMutedAudio(runner))
    }
}
