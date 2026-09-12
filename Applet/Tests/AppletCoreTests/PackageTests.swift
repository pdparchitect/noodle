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
        _ = try first.files()
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
        XCTAssertThrowsError(try package.files())
        XCTAssertThrowsError(try NoodletPackage.child("outside/file", in: destination))
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
    func testInvalidRequestBounds() throws {
        var r = AppletRequest(.click)
        r.x = .nan
        XCTAssertThrowsError(try r.validate())
        r.x = 1
        r.width = 8192
        XCTAssertThrowsError(try r.validate())
    }
}
