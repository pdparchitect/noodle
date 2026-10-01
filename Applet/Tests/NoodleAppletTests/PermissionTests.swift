import AppletBridge
import AppletCore
import NoodletRuntime
import WebKit
import XCTest
@testable import NoodleApplet

@MainActor final class PermissionTests: XCTestCase {
    func testManifestAcceptsKnownPermissionsOnly() throws {
        func manifest(_ permissions: String) throws -> NoodletManifest {
            let manifest = try JSONDecoder().decode(NoodletManifest.self, from: Data(
                #"{"title":"Fixture","runtime":"html","entry":"index.html","permissions":\#(permissions)}"#.utf8))
            try manifest.validate()
            return manifest
        }
        XCTAssertEqual(try manifest(#"["microphone","speech-recognition"]"#).permissions, ["microphone", "speech-recognition"])
        XCTAssertNoThrow(try manifest(#"["camera","screen-capture"]"#))
        XCTAssertThrowsError(try manifest(#"["contacts"]"#))
    }

    /// The network a Mac is on is asked for once per noodlet like the camera, kept, and listed in
    /// Settings to take back; macOS has nothing of its own to say about it.
    func testLocalNetworkIsGrantedOnceAllowedAndListedByName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AppletPermissions." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let package = try NoodletPackage.install([
            "noodlet.json": Data(#"{"title":"Remote","runtime":"html","entry":"index.html","permissions":["local-network"]}"#.utf8),
            "index.html": Data("fixture".utf8),
        ], to: root.appendingPathComponent("Remote.noodlet"))
        XCTAssertEqual(AppletPermissions.status(package, defaults: defaults), ["local-network": "not-requested"])
        defaults.set(["local-network"], forKey: "permissions.\(package.key)")
        XCTAssertEqual(AppletPermissions.status(package, defaults: defaults), ["local-network": "granted"])
        XCTAssertEqual(AppletPermissions.titles["local-network"], "Local Network")
    }

    func testManifestAcceptsKnownCategoriesOnly() throws {
        func manifest(_ category: String) throws -> NoodletManifest {
            let manifest = try JSONDecoder().decode(NoodletManifest.self, from: Data(
                #"{"title":"Fixture","runtime":"html","entry":"index.html","category":"\#(category)"}"#.utf8))
            try manifest.validate()
            return manifest
        }
        XCTAssertEqual(try manifest("games").category, "games")
        XCTAssertNoThrow(try manifest("media"))
        XCTAssertThrowsError(try manifest("other"))
        XCTAssertThrowsError(try manifest("Games"))
    }

    func testRefusedPermissionFailsOpenWithReason() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AppletPermissions." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let library = botLibrary(root: root, defaults: defaults)
        let runtime = AppletRuntime(library: library, defaults: defaults)
        var asked: [String] = []
        runtime.authorize = { package in
            asked = package.manifest.permissions ?? []
            return "Permission was not given."
        }
        var request = AppletRequest(.open)
        request.mode = "headless"
        request.path = try botNoodlet([
            "noodlet.json": Data(#"{"title":"Listener","runtime":"html","entry":"index.html","permissions":["microphone"]}"#.utf8),
            "index.html": Data("fixture".utf8),
        ], named: "Listener", owner: "source", root: root)
        let response = await runtime.handle(request, identity: AppletBuildIdentity.current.noodleID)
        XCTAssertEqual(asked, ["microphone"])
        XCTAssertNotEqual(response.permissions?["microphone"], "granted", "The user refused this noodlet")
        XCTAssertEqual(response.permissions?.keys.sorted(), ["microphone"])
        XCTAssertEqual(response.state, "failed")
        XCTAssertEqual(response.failure, "Permission was not given.")
        XCTAssertTrue(response.error?.hasPrefix("Permission was not given.") == true)

        var status = AppletRequest(.status, sessionID: response.sessionID)
        status.owner = "local"
        let later = await runtime.handle(status, identity: AppletBuildIdentity.current.noodleID)
        XCTAssertNil(later.error, "Reporting a failure must not fail the status command")
        XCTAssertEqual(later.failure, "Permission was not given.")
    }

    func testGrantsAreListedAndRevoked() {
        let suite = "AppletPermissions." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["camera", "microphone"], forKey: "permissions.fixture")
        XCTAssertEqual(AppletPermissions.grants(defaults: defaults)["fixture"], ["camera", "microphone"])
        AppletPermissions.revoke(packageKey: "fixture", defaults: defaults)
        XCTAssertNil(AppletPermissions.grants(defaults: defaults)["fixture"])
    }

    func testMediaCaptureDelegateIsVisibleToWebKit() {
        XCTAssertTrue(NoodletPage.instancesRespond(to: Selector(
            ("webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:"))))
        XCTAssertTrue(NoodletPage.instancesRespond(to: NoodletPage.displayCaptureSelector))
    }
}
