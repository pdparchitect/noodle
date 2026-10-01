import XCTest
@testable import NoodleCore

final class MCPInvocationTests: XCTestCase {
    func testReadableNamesAreUniqueAndStable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try MCPConnectionRecord(name: "Notion", endpoint: URL(string: "https://mcp.notion.com/mcp")!)
        let second = try MCPConnectionRecord(name: "Notion", endpoint: first.endpoint)
        var registry = MCPRegistry()
        registry.connections = [first, second]
        let agent = UUID()
        try registry.assign([second.id], to: agent)
        try registry.save(root: root)
        XCTAssertEqual(registry.connections.map(\.skillName), ["mcp-notion", "mcp-notion-2"])
        registry.connections[1].name = "New display name"
        registry.remove(first.id)
        try registry.save(root: root)
        XCTAssertEqual(try MCPRegistry.load(root: root).connections[0].skillName, "mcp-notion-2")
    }

    func testBrokerResolvesOnlyAssignedNamesAndRejectsAmbiguousTargets() throws {
        let connection = try MCPConnectionRecord(name: "Notion", endpoint: URL(string: "https://mcp.notion.com/mcp")!)
        let request = MCPBridgeRequest(session: "test", skillName: connection.skillName, action: .tools, tool: nil, arguments: nil)
        XCTAssertEqual(request.assignedConnection(in: [connection]), connection)
        XCTAssertNil(request.assignedConnection(in: []))
        let ambiguous = MCPBridgeRequest(session: "test", connectionID: connection.id, skillName: connection.skillName, action: .tools, tool: nil, arguments: nil)
        XCTAssertNil(ambiguous.assignedConnection(in: [connection]))
        let decoded = try JSONDecoder().decode(MCPBridgeRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.skillName, connection.skillName)
        XCTAssertNil(decoded.connectionID)
        let legacy = MCPBridgeRequest(session: "test", connectionID: connection.id, action: .tools, tool: nil, arguments: nil)
        XCTAssertEqual(try JSONDecoder().decode(MCPBridgeRequest.self, from: JSONEncoder().encode(legacy)).assignedConnection(in: [connection]), connection)
    }

    func testNewReadableNameCannotOverwriteAnUnmanagedSkill() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent(".agents/skills/mcp-notion")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("SKILL.md")
        try "My own skill".write(to: file, atomically: true, encoding: .utf8)
        let connection = try MCPConnectionRecord(name: "Notion", endpoint: URL(string: "https://mcp.notion.com/mcp")!)
        ToolProviderSkills.synchronize(workspace: root, providers: [(ConnectionToolProvider(id: connection.skillName, title: connection.name,
            connection: connection.id) { _, _, _, _, _ in Data() }.manifest, [])])
        XCTAssertEqual(try String(contentsOf: file), "My own skill")
    }
}
