import AppKit
import AppletBridge
import AppletCore
import Darwin
import Surface
import SwiftUI
import WebKit
import XCTest

@testable import NoodleApplet

/// A noodlet someone watched and used remotely is really gone once it is closed,
/// while it keeps running, watched, for as long as it is open.
@MainActor final class LiveViewCloseTests: XCTestCase {
    private func makeRuntime() throws -> (AppletRuntime, AppletLibrary) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "LiveViewClose." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let library = botLibrary(root: root, defaults: defaults)
        return (AppletRuntime(library: library, defaults: defaults), library)
    }

    private func install(_ runtime: AppletRuntime, _ library: AppletLibrary) async throws -> NoodletPackage {
        var validate = AppletRequest(.validate)
        validate.path = try botNoodlet([
            "noodlet.json": try JSONEncoder().encode(NoodletManifest(title: "Watched")),
            "index.html": Data("<title>Watched</title><button>Go</button>".utf8),
        ], named: "Watched", owner: "author", root: library.root)
        validate.owner = "author"
        let response = try await runtime.handle(validate, identity: AppletBuildIdentity.current.noodleID).checked()
        return try library.package(for: try XCTUnwrap(response.noodletID))
    }

    private func open(_ runtime: AppletRuntime, _ package: NoodletPackage, mode: String) async throws -> AppletSession {
        var request = AppletRequest(.open)
        request.path = package.url.path
        request.owner = "author"
        request.mode = mode
        let response = try await runtime.handle(request, identity: AppletBuildIdentity.current.noodleID).checked()
        return try XCTUnwrap(runtime.sessions[try XCTUnwrap(response.sessionID)])
    }

    /// A viewer's connection: the end the Applet streams into, and the end the viewer holds.
    private func watch(_ runtime: AppletRuntime, _ session: AppletSession) async throws -> (applet: SurfaceSocket, viewer: SurfaceSocket) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let ends = (applet: SurfaceSocket(fd: fds[0]), viewer: SurfaceSocket(fd: fds[1]))
        addTeardownBlock { ends.applet.close(); ends.viewer.close() }
        _ = try await runtime.handle(
            AppletRequest(.surfaceStream, sessionID: session.id), identity: AppletBuildIdentity.current.noodleID,
            surface: ends.applet).checked()
        return ends
    }

    private func isBusy(_ runtime: AppletRuntime, _ session: AppletSession) async -> Bool {
        var eval = AppletRequest(.eval, sessionID: session.id)
        eval.text = "1"
        return await runtime.handle(eval, identity: AppletBuildIdentity.current.noodleID).errorCode == "session-busy"
    }

    /// Closing with the window's close button lets go of the page a remote viewer clicked in.
    func testClosingANoodletUsedRemotelyReleasesItsPage() async throws {
        let (runtime, library) = try makeRuntime()
        let package = try await install(runtime, library)
        let session = try await open(runtime, package, mode: "foreground")
        try await runtime.deliver(.pointer(.down, x: 10, y: 10, clickCount: 1), to: session)
        try await runtime.deliver(.pointer(.up, x: 10, y: 10, clickCount: 1), to: session)
        // Lets the main queue drain what the clicks autoreleased, as the app's run loop does.
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        weak var page: WKWebView?
        autoreleasepool {
            page = session.web?.web
            session.web?.window.performClose(nil)
        }
        XCTAssertEqual(session.state, "stopped")
        XCTAssertNil(page, "the closed noodlet's page stayed loaded")
    }

    /// Closing with the window's close button ends the live view instead of leaving
    /// every viewer on a frozen picture.
    func testClosingAWatchedNoodletEndsItsLiveView() async throws {
        let (runtime, library) = try makeRuntime()
        let package = try await install(runtime, library)
        let session = try await open(runtime, package, mode: "foreground")
        let first = try await watch(runtime, session)
        let second = try await watch(runtime, session)
        session.web?.window.performClose(nil)
        XCTAssertEqual(session.state, "stopped")
        XCTAssertTrue(first.applet.isClosed, "the live view of a closed noodlet stayed open")
        XCTAssertTrue(second.applet.isClosed, "the live view of a closed noodlet stayed open")
    }

    /// Without a remote viewer, closing already lets go of the page; this pins the check above.
    func testClosingAnUnwatchedNoodletReleasesItsPage() async throws {
        let (runtime, library) = try makeRuntime()
        let package = try await install(runtime, library)
        let session = try await open(runtime, package, mode: "foreground")
        weak var page: WKWebView?
        autoreleasepool {
            page = session.web?.web
            session.web?.window.performClose(nil)
        }
        // WebKit can hold the page until the main queue drains, as the app's run loop does.
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        XCTAssertEqual(session.state, "stopped")
        XCTAssertNil(page)
    }

    /// A background noodlet shared by several viewers keeps running and keeps bots off it
    /// while anyone is still watching, and one viewer leaving does not end it for the rest.
    func testAWatchedBackgroundNoodletStaysUpForItsOtherViewers() async throws {
        let (runtime, library) = try makeRuntime()
        let package = try await install(runtime, library)
        let session = try await open(runtime, package, mode: "background")
        defer { session.stop() }
        let first = try await watch(runtime, session)
        let second = try await watch(runtime, session)
        try await runtime.deliver(.pointer(.down, x: 10, y: 10, clickCount: 1), to: session)
        let busy = await isBusy(runtime, session)
        XCTAssertTrue(busy)

        first.viewer.close()
        for await _ in first.applet.frames {}
        await Task.yield()
        XCTAssertEqual(session.state, "running")
        XCTAssertNotNil(session.web)
        XCTAssertFalse(second.applet.isClosed)
        let stillBusy = await isBusy(runtime, session)
        XCTAssertTrue(stillBusy)
    }

    /// Opening a closed noodlet again starts a session that can be watched and used afresh.
    func testAReopenedNoodletCanBeWatchedAgain() async throws {
        let (runtime, library) = try makeRuntime()
        let package = try await install(runtime, library)
        let old = try await open(runtime, package, mode: "background")
        _ = try await watch(runtime, old)
        _ = try await runtime.handle(AppletRequest(.close, sessionID: old.id), identity: AppletBuildIdentity.current.noodleID).checked()

        let new = try await open(runtime, package, mode: "background")
        defer { new.stop() }
        XCTAssertNotEqual(new.id, old.id)
        let viewer = try await watch(runtime, new)
        try await runtime.deliver(.pointer(.down, x: 10, y: 10, clickCount: 1), to: new)
        XCTAssertFalse(viewer.applet.isClosed)
        let busy = await isBusy(runtime, new)
        XCTAssertTrue(busy)
    }

    /// A page something still holds after its noodlet stopped is emptied and silenced, so a game
    /// cannot play on out of sight until the Applet quits.
    func testAStoppedNoodletsPageIsEmptiedEvenIfStillHeld() async throws {
        let (runtime, library) = try makeRuntime()
        let package = try await install(runtime, library)
        let session = try await open(runtime, package, mode: "foreground")
        let runner = try XCTUnwrap(session.web)
        runner.window.performClose(nil)
        XCTAssertEqual(session.state, "stopped")
        XCTAssertTrue(runner.muted)
        var location = ""
        for _ in 0..<100 where location != "about:blank" {
            location = try await runner.web.evaluateJavaScript("location.href") as? String ?? ""
            if location != "about:blank" { try await Task.sleep(for: .milliseconds(50)) }
        }
        XCTAssertEqual(location, "about:blank", "the stopped noodlet's page kept running")
    }

    /// The menu bar keeps its items after a noodlet closes; its Play On and Bring Back items
    /// must not keep the closed noodlet, and the game in it, alive.
    func testTheCastMenuDoesNotKeepAClosedNoodletAlive() throws {
        for casting in [true, false] {
            weak var gone: CastTargetStub?
            var body: (any View)?
            autoreleasepool {
                let target = CastTargetStub(casting: casting)
                gone = target
                body = NoodletCastMenu(target: target).body
            }
            XCTAssertNotNil(body)
            XCTAssertNil(gone, "a menu item kept the noodlet alive (casting: \(casting))")
        }
    }
}

@MainActor private final class CastTargetStub: NoodletCastTarget {
    let isCasting: Bool
    var canCast: Bool { true }
    init(casting: Bool) { isCasting = casting }
    func play(on screen: NSScreen) {}
    func bringBack() {}
}
