import Foundation
import HubCore
import XCTest

@MainActor final class HubTests: XCTestCase {
    /// The Agent Host finds bots under Application Support/Noodle in the Hub's container.
    func testHubStoresDataWhereItsAgentHostLooks() {
        let applicationSupport = URL(fileURLWithPath: "/tmp/Application Support", isDirectory: true)
        XCTAssertEqual(Hub.root(applicationSupport: applicationSupport),
                       applicationSupport.appendingPathComponent("Noodle", isDirectory: true))
    }

    func testHubServesItsConversationsWithItsOwnToken() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-start-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(root: root, messenger: nil)
        await hub.startServer(port: 0)
        defer { hub.stopServer() }
        let port = try XCTUnwrap(hub.serverPort, hub.serverError ?? "")
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/conversations")!)
        request.setValue("Bearer \(try hub.accessToken())", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
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

final class HubAccessTokenTests: XCTestCase {
    func testTheTokenIsCreatedOnceAndKeptPrivate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-token-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let first = try HubAccessToken.load(root: root)
        XCTAssertGreaterThanOrEqual(first.count, 43)
        XCTAssertEqual(try HubAccessToken.load(root: root), first)
        let file = root.appendingPathComponent(HubAccessToken.fileName)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }
}
