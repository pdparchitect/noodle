import AppletBridge
import AppletCore
import XCTest

final class NoodletRegistryTests: XCTestCase {
    func testIdentitySurvivesUpdatesReloadAndMovesButCopiesAreIndependent() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let source = root.appendingPathComponent("A.noodlet")
        try manager.createDirectory(at: source, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("registry.json")
        let registry = try NoodletRegistry(file: file)
        let id = try registry.id(for: source)
        try Data("updated".utf8).write(to: source.appendingPathComponent("index.html"))
        XCTAssertEqual(try registry.id(for: source), id)
        let reloaded = try NoodletRegistry(file: file)
        XCTAssertEqual(reloaded.resolve(id)?.path, source.resolvingSymlinksInPath().path)
        let copy = root.appendingPathComponent("Copy.noodlet")
        try manager.copyItem(at: source, to: copy)
        XCTAssertNotEqual(try reloaded.id(for: copy), id)
        let moved = root.appendingPathComponent("Moved.noodlet")
        try manager.moveItem(at: source, to: moved)
        XCTAssertEqual(reloaded.resolve(id)?.path, moved.resolvingSymlinksInPath().path)
        XCTAssertEqual(try reloaded.id(for: moved), id)
        try manager.removeItem(at: moved)
        XCTAssertNil(reloaded.resolve(id))
        XCTAssertNil(reloaded.resolve(UUID()))
        try Data("corrupt".utf8).write(to: file)
        XCTAssertThrowsError(try NoodletRegistry(file: file))
    }

    func testLinksAreStrictAndCannotCombineIDWithAnotherTarget() throws {
        let id = UUID(), url = NoodletLink.url(for: UUID())
        XCTAssertEqual(NoodletLink.id(in: NoodletLink.url(for: id)), id)
        for string in [url.absoluteString + "/", url.absoluteString + "/file.noodlet",
                       url.absoluteString + "?path=/tmp/a", url.absoluteString + "#fragment",
                       "noodlet://user@\(id)", "noodlet://\(id):80", "noodlet:///tmp/a.noodlet",
                       "noodlet://open/\(id)", "https://\(id)", "noodlet://hello"] {
            XCTAssertNil(NoodletLink.id(in: URL(string: string)!), string)
        }
        for target in 0..<3 {
            var request = AppletRequest(.open)
            request.noodletID = id
            XCTAssertNoThrow(try request.validate())
            if target == 0 { request.path = "/tmp/a.noodlet" }
            if target == 1 { request.sessionID = UUID() }
            if target == 2 { request.files = [:] }
            XCTAssertThrowsError(try request.validate())
        }
    }
}
