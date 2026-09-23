import Foundation
import HubCore
import XCTest

@MainActor final class HubTests: XCTestCase {
    func testHubKeepsItsDataApartFromNoodle() {
        let applicationSupport = URL(fileURLWithPath: "/tmp/Application Support", isDirectory: true)
        let root = Hub.root(applicationSupport: applicationSupport)
        XCTAssertEqual(root.lastPathComponent, "Noodle Hub")
        XCTAssertNotEqual(root, applicationSupport.appendingPathComponent("Noodle", isDirectory: true))
    }

    func testHubStoresBotsUnderItsRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-tests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(root: root, messenger: nil)
        try hub.repository.prepare()
        let created = try hub.repository.createAgent(named: "Alfred")
        XCTAssertTrue(hub.repository.directory(for: created.agent).path.hasPrefix(root.path))
    }
}
