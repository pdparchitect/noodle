import AppletBridge
import XCTest

@testable import AppletCore

final class PackageTests: XCTestCase {
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func files(_ text: String = "hello") throws -> [String: Data] {
        [
            "noodlet.json": try JSONEncoder().encode(NoodletManifest(title: "Test")),
            "index.html": Data(text.utf8),
        ]
    }
    func testInstallUpdateAndRevision() throws {
        let root = try temporary().appendingPathComponent("Test.noodlet")
        let first = try NoodletPackage.install(files(), to: root)
        let revision = first.revision
        XCTAssertEqual(first.manifest.title, "Test")
        let second = try NoodletPackage.install(files("changed"), to: root)
        XCTAssertNotEqual(revision, second.revision)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("index.html"), encoding: .utf8),
            "changed")
    }
    func testRejectTraversalAndSymlinks() throws {
        let root = try temporary()
        let destination = root.appendingPathComponent("Test.noodlet")
        var payload = try files()
        payload["../escaped"] = Data()
        XCTAssertThrowsError(try NoodletPackage.install(payload, to: destination))
        let package = try NoodletPackage.install(files(), to: destination)
        try FileManager.default.createSymbolicLink(
            at: destination.appendingPathComponent("outside"), withDestinationURL: root)
        XCTAssertEqual(try package.names(), ["index.html", "noodlet.json"])
        XCTAssertThrowsError(try NoodletPath.child("outside/file", in: destination))
    }
    /// Nothing is sent anywhere, so a package may be as large as its assets need.
    func testALargePackageHasARevision() throws {
        let root = try temporary().appendingPathComponent("Large.noodlet")
        let package = try NoodletPackage.install(files(), to: root)
        try Data(count: 21 * 1_048_576).write(to: root.appendingPathComponent("movie.mp4"))
        XCTAssertNotEqual(package.revision, "unreadable")
    }
    /// A bot may keep its noodlet under git; hidden folders are not part of it.
    func testRevisionLeavesOutHiddenFilesAndLinks() throws {
        let root = try temporary()
        let destination = root.appendingPathComponent("Test.noodlet")
        let package = try NoodletPackage.install(files(), to: destination)
        let revision = package.revision
        try FileManager.default.createDirectory(
            at: destination.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("ref".utf8).write(to: destination.appendingPathComponent(".git/HEAD"))
        try Data().write(to: destination.appendingPathComponent(".DS_Store"))
        try FileManager.default.createSymbolicLink(
            at: destination.appendingPathComponent("outside"), withDestinationURL: root)
        XCTAssertEqual(package.revision, revision)
    }
    func testARuntimeOtherThanHTMLIsRejected() throws {
        let root = try temporary().appendingPathComponent("Orbit.noodlet")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"version":1,"title":"Orbit","runtime":"swift","entry":"Main.swift"}"#.utf8)
            .write(to: root.appendingPathComponent("noodlet.json"))
        XCTAssertThrowsError(try NoodletPackage(url: root)) {
            XCTAssertEqual($0.localizedDescription, "Runtime must be html.")
        }
    }
    func testLockCanonicalLocationAndRelease() throws {
        let root = try temporary()
        let file = root.appendingPathComponent("Test.noodlet")
        let locks = root.appendingPathComponent("locks")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("Alias.noodlet")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        var lock: InstanceLock? = try InstanceLock(location: file, directory: locks)
        XCTAssertNotNil(lock)
        XCTAssertThrowsError(try InstanceLock(location: alias, directory: locks))
        lock = nil
        XCTAssertNoThrow(try InstanceLock(location: alias, directory: locks))
    }
    func testLogCursorAndDurability() throws {
        let url = try temporary().appendingPathComponent("log.jsonl")
        let log = AppletLog(url: url)
        log.append("first", channel: "stdout")
        let (a, cursor) = try log.read(offset: 0)
        log.append("second", channel: "stderr")
        let (b, end) = try AppletLog(url: url).read(offset: cursor)
        XCTAssertTrue(String(decoding: a, as: UTF8.self).contains("first"))
        XCTAssertTrue(String(decoding: b, as: UTF8.self).contains("second"))
        XCTAssertFalse(String(decoding: b, as: UTF8.self).contains("first"))
        XCTAssertGreaterThan(end, cursor)
    }
    /// A game declares its controls in noodlet.json; the phone shows them in place of the keyboard.
    func testManifestDeclaresControls() throws {
        let root = try temporary().appendingPathComponent("Game.noodlet")
        func install(_ controls: String) throws -> NoodletPackage {
            let manifest = #"{"title":"Game","runtime":"html","entry":"index.html","controls":\#(controls)}"#
            return try NoodletPackage.install(["noodlet.json": Data(manifest.utf8), "index.html": Data("<p>".utf8)], to: root)
        }
        let package = try install(#"{"pads":[{"left":"left","right":"right"}],"buttons":[{"key":"space","label":"Jump"}],"menu":"escape"}"#)
        XCTAssertEqual(package.manifest.controls, Gamepad(pads: [Gamepad.Pad(left: "left", right: "right")],
                                                          buttons: [Gamepad.Button(key: "space", label: "Jump")], menu: "escape"))
        XCTAssertThrowsError(try install(#"{"buttons":[{"key":"F1"}]}"#))
        XCTAssertThrowsError(try install(#"{}"#))
        XCTAssertNil(try NoodletPackage.install(files(), to: try temporary().appendingPathComponent("Plain.noodlet")).manifest.controls)
    }
    func testInvalidRequestBounds() throws {
        var r = AppletRequest(.click)
        r.x = .nan
        XCTAssertThrowsError(try r.validate())
        r.x = 1
        r.width = 8192
        XCTAssertThrowsError(try r.validate())
    }
    func testSharedSessionAndTestClockProtocol() throws {
        var request = AppletRequest(.status, sessionID: UUID())
        request.noodletID = UUID()
        XCTAssertNoThrow(try request.validate())
        request.path = "/other.noodlet"
        XCTAssertThrowsError(try request.validate())
        request.path = nil; request.operation = .open
        XCTAssertThrowsError(try request.validate())
        request.sessionID = nil; request.testClock = true; request.mode = "background"
        XCTAssertThrowsError(try request.validate())
        request.mode = "headless"
        XCTAssertNoThrow(try request.validate())
        let decoded = try JSONDecoder().decode(AppletRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.testClock, true)
        request = AppletRequest(.step, sessionID: UUID())
        for count in [0, 601, Int.max] { request.frames = count; XCTAssertThrowsError(try request.validate()) }
        request.frames = 60
        XCTAssertNoThrow(try request.validate())
        XCTAssertEqual(try JSONDecoder().decode(AppletRequest.self, from: JSONEncoder().encode(request)).frames, 60)
        let legacy = try JSONDecoder().decode(AppletResponse.self, from: Data("{\"version\":1,\"state\":\"running\"}".utf8))
        XCTAssertNil(legacy.rendering)
        XCTAssertNil(legacy.testClock)
        let diagnostics = Data("""
            {"version":1,"mode":"headless","dataScope":"test","testClock":true,"viewAvailable":true,
             "errorCode":"session-not-running","rendering":{"readyState":"complete","visibilityState":"visible",
             "nativeVisibilityState":"hidden","synthetic":true,"animationFrameCount":60,"lastAnimationFrameTimestamp":1000}}
            """.utf8)
        let response = try JSONDecoder().decode(AppletResponse.self, from: diagnostics)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as! NSDictionary
        XCTAssertEqual(encoded, try JSONSerialization.jsonObject(with: diagnostics) as! NSDictionary)
    }
}
