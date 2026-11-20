import Foundation
import HubCore
import NoodleCore
@testable import NoodleMCP
import NoodleRuntime
import XCTest

/// A Hub, and Noodle Server, which runs the same core, watches its people's tool connections as Noodle does: running
/// the bots starts the watch, a connection with something new wakes the bots it is assigned to, each check is in the
/// connection's activity, and stopping the bots stops the watch.
@MainActor final class HubConnectionsWatchTests: XCTestCase {
    func testAHubWakesTheBotsAWatchedConnectionIsAssignedTo() async throws {
        let (runtime, _) = try fakeRuntime()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-watch-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("Noodle"))
        try repository.prepare()
        let kai = try repository.createAgent(named: "Kai").agent
        let access = HubAccess(url: root.appendingPathComponent("access.json"))
        let ada = try access.addUser(named: "Ada")
        access.setOwner(ada, ofBot: kai.id)
        let service = ToolConnectionService(credentials: NoCredentials(), oauth: MCPOAuth(), httpConfiguration: { .ephemeral })
        let connections = HubConnections(root: root, access: access, service: service,
                                         tools: ToolProviderRegistry(), assignments: ToolAssignmentStore())
        let feed = HubFeedAdapter()
        connections.store.serve(["feed": feed])
        await service.useAdapters(["feed": feed])
        var record = try ToolConnection(name: "Alerts", endpoint: URL(string: "https://example.com/api")!)
        record.adapter = "feed"
        let alerts = try connections.add(record, for: ada)
        try connections.assign([alerts.id], to: kai.id, for: ada)
        await connections.store.readSignIns()
        let bots = HubBots(repository: repository, runtime: runtime, access: access, connections: connections,
                           computers: nil, browsers: nil, applets: nil,
                           uploads: root.appendingPathComponent("Uploads", isDirectory: true),
                           readMarks: root.appendingPathComponent("read.json"), pins: nil, notifications: nil)

        try bots.start()
        XCTAssertTrue(connections.store.isWatching, "Running the Hub's bots watches their tools")
        let now = Date()
        var woken: [(UUID, String)] = []
        await connections.store.checkWatched(at: now) { woken.append(($0, $1)) }
        XCTAssertTrue(woken.isEmpty, "The first check only marks where watching starts")
        feed.found = [ServiceAlert(id: "a1", time: now.addingTimeInterval(60))]
        await connections.store.checkWatched(at: now.addingTimeInterval(300)) { woken.append(($0, $1)) }
        XCTAssertEqual(woken.map(\.0), [kai.id])
        XCTAssertTrue(woken.first?.1.contains(#"<tool-alerts account="Alerts""#) == true, "\(woken)")
        let log = connections.activity.log(for: alerts.id).text
        XCTAssertTrue(log.contains("Found 1 new alert; woke Kai"), log)

        bots.stop()
        XCTAssertFalse(connections.store.isWatching, "Stopping the bots stops the watch")
    }
}

/// An adapter whose service has a feed: it answers with what the test puts there.
private final class HubFeedAdapter: ToolConnectionAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var alerts: [ServiceAlert] = []
    var found: [ServiceAlert] { get { lock.withLock { alerts } } set { lock.withLock { alerts = newValue } } }
    var watchedTool: String? { "read-alerts" }
    func tools(for connection: ToolConnection) async throws -> Data {
        Data(#"{"tools":[{"name":"read-alerts","inputSchema":{"type":"object"}}]}"#.utf8)
    }
    func call(_ tool: String, arguments: Data, connection: ToolConnection, access: ToolConnectionAccess) async throws -> Data {
        Data(#"{"content":[],"isError":false}"#.utf8)
    }
    func alerts(since: Date, connection: ToolConnection, access: ToolConnectionAccess) async throws -> [ServiceAlert] {
        lock.withLock { alerts }
    }
}
