import AppletCore
import AppKit
import XCTest

@testable import NoodleApplet

/// Playing a noodlet on a TV takes its window full screen on that display, which a fixed-size
/// or floating window cannot do; bringing it back must leave the window as the manifest made it.
/// HTML and Swift noodlets share the same window handling.
final class CastTests: XCTestCase {
    @MainActor private func install(_ runtime: String, window: String) throws -> (NoodletPackage, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let entry = runtime == "html" ? "index.html" : "main.swift"
        let manifest = #"{"version":1,"title":"Game","runtime":"\#(runtime)","entry":"\#(entry)","window":\#(window)}"#
        let package = try NoodletPackage.install([
            "noodlet.json": Data(manifest.utf8),
            entry: Data("<title>Game</title>".utf8),
        ], to: root.appendingPathComponent("Game.noodlet"))
        return (package, root)
    }

    @MainActor private func makeRunner(window: String) throws -> (WebRunner, URL) {
        let (package, root) = try install("html", window: window)
        let runner = WebRunner(
            package: package, dataRoot: root, log: AppletLog(url: root.appendingPathComponent("log.txt")),
            size: CGSize(width: 320, height: 240), storeID: UUID(), rememberFrame: false)
        return (runner, root)
    }

    @MainActor private func makeNative(window: String) throws -> (NativeRunner, URL) {
        let (package, root) = try install("swift", window: window)
        let runner = NativeRunner(
            package: package, dataRoot: root, buildRoot: root.appendingPathComponent("Build"),
            log: AppletLog(url: root.appendingPathComponent("log.txt")))
        return (runner, root)
    }

    @MainActor func testCastingLiftsTheLimitsAndBringingBackRestoresThem() throws {
        let (runner, root) = try makeRunner(
            window: #"{"type":"floating","resizable":false,"maxWidth":400,"maxHeight":300}"#)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { runner.stop() }
        let window = runner.window
        let frame = window.frame
        let cast = NoodletCast(window)
        var changes = 0
        cast.changed = { changes += 1 }
        XCTAssertTrue(cast.canCast)

        cast.lift(onto: try XCTUnwrap(NSScreen.screens.last))
        XCTAssertTrue(cast.isCasting)
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertGreaterThan(window.contentMaxSize.width, 10_000)
        XCTAssertEqual(window.level, .normal)
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenAuxiliary))

        window.setFrame(CGRect(x: 0, y: 0, width: 900, height: 700), display: false)
        cast.bringBack()
        XCTAssertFalse(cast.isCasting)
        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.contentMaxSize, CGSize(width: 400, height: 300))
        XCTAssertEqual(window.level, .floating)
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertEqual(window.frame, frame)
        XCTAssertEqual(changes, 2)
    }

    /// A quick-look panel is not something to play on a TV, whichever runtime draws it.
    @MainActor func testPreviewPanelsCannotBeCast() throws {
        let (web, webRoot) = try makeRunner(window: #"{"type":"preview"}"#)
        defer { try? FileManager.default.removeItem(at: webRoot) }
        defer { web.stop() }
        XCTAssertFalse(web.canCast)
        let (native, nativeRoot) = try makeNative(window: #"{"type":"preview"}"#)
        defer { try? FileManager.default.removeItem(at: nativeRoot) }
        XCTAssertFalse(native.canCast)
        let (game, gameRoot) = try makeNative(window: #"{"type":"standard"}"#)
        defer { try? FileManager.default.removeItem(at: gameRoot) }
        XCTAssertTrue(game.canCast)
    }

    /// A Swift noodlet's window lives in its own process, which reports when it plays on
    /// another display so the library can offer to bring it back.
    @MainActor func testASwiftNoodletReportsWhenItPlaysElsewhere() throws {
        let (native, root) = try makeNative(window: #"{"type":"standard"}"#)
        defer { try? FileManager.default.removeItem(at: root) }
        var changes = 0
        native.castChanged = { changes += 1 }
        XCTAssertFalse(native.isCasting)
        native.receive(native.prefix + #"{"id":"cast","value":true}"#)
        XCTAssertTrue(native.isCasting)
        native.receive(native.prefix + #"{"id":"cast","value":false}"#)
        XCTAssertFalse(native.isCasting)
        XCTAssertEqual(changes, 2)
    }
}
