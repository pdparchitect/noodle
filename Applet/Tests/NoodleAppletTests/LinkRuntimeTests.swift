import AppletBridge
import AppletCore
import XCTest
@testable import NoodleApplet

@MainActor final class LinkRuntimeTests: XCTestCase {
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
