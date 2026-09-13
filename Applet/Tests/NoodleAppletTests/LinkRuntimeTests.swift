import AppletBridge
import AppletCore
import XCTest
@testable import NoodleApplet

@MainActor final class LinkRuntimeTests: XCTestCase {
    func testSharedSelectionPrefersActiveThenNewestAndConstrainsExplicitSessions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "SessionSelection." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let library = AppletLibrary(root: root, defaults: defaults, installExamples: false, watchChanges: false)
        let runtime = AppletRuntime(library: library, defaults: defaults)
        defer { runtime.shutdown(); try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let identity = "com.pdparchitect.noodle.local"
        var request = AppletRequest(.validate)
        request.path = "/author/Game.noodlet"; request.owner = "author"
        request.files = ["noodlet.json": try JSONEncoder().encode(NoodletManifest(title: "Game")), "index.html": Data("game".utf8)]
        let registered = try await runtime.handle(request, identity: identity).checked()
        let package = try NoodletPackage(url: URL(fileURLWithPath: XCTUnwrap(registered.path)))
        func session(_ mode: String) throws -> AppletSession {
            let value = try AppletSession(package: package, owner: "author", mode: mode,
                size: CGSize(width: 320, height: 240), root: root)
            runtime.sessions[value.id] = value
            return value
        }
        let old = try session("background"); old.stop()
        let latest = try session("headless")
        var status = AppletRequest(.status); status.noodletID = registered.noodletID; status.owner = "local"
        for state in ["starting", "building", "running", "failed", "stopped"] {
            latest.state = state
            let response = try await runtime.handle(status, identity: identity).checked()
            XCTAssertEqual(response.sessionID, latest.id, state)
            XCTAssertEqual(response.mode, "headless")
            XCTAssertEqual(response.dataScope, "test")
        }
        // A newer completed operation must not displace an active session.
        latest.lock = nil
        let newer = try session("background"); newer.stop(); latest.state = "running"
        do { let response = await runtime.handle(status, identity: identity); XCTAssertEqual(response.sessionID, latest.id) }
        latest.stop()
        status.sessionID = old.id
        do { let response = await runtime.handle(status, identity: identity); XCTAssertEqual(response.sessionID, old.id) }
        status.operation = .inspect
        let stopped = await runtime.handle(status, identity: identity)
        XCTAssertEqual(stopped.sessionID, old.id)
        XCTAssertEqual(stopped.errorCode, "session-not-running")
        status.operation = .status
        status.sessionID = UUID()
        do { let response = await runtime.handle(status, identity: identity); XCTAssertEqual(response.errorCode, "session-unavailable") }
        request.path = "/author/Other.noodlet"
        let other = try await runtime.handle(request, identity: identity).checked()
        status.noodletID = other.noodletID; status.sessionID = old.id
        do { let response = await runtime.handle(status, identity: identity); XCTAssertEqual(response.errorCode, "session-unavailable") }
        status.noodletID = registered.noodletID; status.owner = "stranger"
        do { let response = await runtime.handle(status, identity: identity); XCTAssertEqual(response.errorCode, "session-unavailable") }
        status.owner = "local"
        runtime.shutdown()
        let restored = AppletRuntime(library: library, defaults: defaults)
        do { let response = await restored.handle(status, identity: identity); XCTAssertEqual(response.sessionID, old.id) }
        status.noodletID = other.noodletID
        do { let response = await restored.handle(status, identity: identity); XCTAssertEqual(response.errorCode, "session-unavailable") }
    }
    func testValidateRegistersWithoutRunningAndInfoEnforcesOwnership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "NoodletLinkTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let library = AppletLibrary(root: root, defaults: defaults, installExamples: false, watchChanges: false)
        let runtime = AppletRuntime(library: library, defaults: defaults)
        let identity = "com.pdparchitect.noodle.local"
        var validate = AppletRequest(.validate)
        validate.path = "/workspace/Hello.noodlet"
        validate.owner = "author"
        validate.files = ["noodlet.json": try JSONEncoder().encode(NoodletManifest(title: "Hello")),
                          "index.html": Data("<h1>Hello</h1>".utf8)]
        let result = try await runtime.handle(validate, identity: identity).checked()
        let id = try XCTUnwrap(result.noodletID)
        XCTAssertEqual(result.url, NoodletLink.url(for: id))
        XCTAssertEqual(result.state, "valid")
        XCTAssertNil(result.sessionID)
        XCTAssertTrue(runtime.sessions.isEmpty)
        var info = AppletRequest(.info)
        info.noodletID = id; info.owner = "author"
        let resolved = try await runtime.handle(info, identity: identity).checked()
        XCTAssertEqual(resolved.path, result.path)
        XCTAssertEqual(resolved.title, "Hello")
        XCTAssertNil(resolved.previewBookmark)
        info.owner = "stranger"
        let denied = await runtime.handle(info, identity: identity)
        XCTAssertNotNil(denied.error)
        info.owner = "author"; info.includePreview = true
        let scopedDenied = await runtime.handle(info, identity: identity)
        XCTAssertNotNil(scopedDenied.error)
        info.owner = "local"
        let preview = try await runtime.handle(info, identity: identity).checked()
        XCTAssertNotNil(preview.previewBookmark)
        XCTAssertNil(preview.sessionID)
        XCTAssertTrue(runtime.sessions.isEmpty, "Loading an attachment preview must not run the creation")
        let cliDenied = await runtime.handle(info, identity: "com.pdparchitect.noodle.applet.cli")
        XCTAssertNotNil(cliDenied.error)
        validate.files?["index.html"] = Data("updated".utf8)
        let updated = try await runtime.handle(validate, identity: identity).checked()
        XCTAssertEqual(updated.noodletID, id)
        let recreated = AppletRuntime(library: AppletLibrary(root: root, defaults: defaults,
            installExamples: false, watchChanges: false), defaults: defaults)
        let afterRestart = try await recreated.handle(info, identity: identity).checked()
        XCTAssertEqual(afterRestart.noodletID, id)
        try FileManager.default.removeItem(atPath: try XCTUnwrap(result.path))
        let missing = await recreated.handle(info, identity: identity)
        XCTAssertNotNil(missing.error)
        XCTAssertTrue(recreated.sessions.isEmpty)
    }
}
