import XCTest
@testable import NoodleCore

final class MCPInvocationTests: XCTestCase {
    func testReadableNamesAreUniqueStableAndMigrateWithoutChangingAccounts() throws {
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

        // A real legacy registry and generated folder, including a user's extra file.
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as! [String: Any]
        let oldName = "mcp-notion-" + first.id.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        object["skillName"] = oldName
        let legacy = try JSONDecoder().decode(MCPConnectionRecord.self, from: JSONSerialization.data(withJSONObject: object))
        let legacyRegistry = ["connections": [object], "assignments": [agent.uuidString.lowercased(): [first.id.uuidString]] ] as [String: Any]
        try JSONSerialization.data(withJSONObject: legacyRegistry).write(to: root.appendingPathComponent("MCP/connections.json"))
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        // The folder an earlier Noodle wrote for the old name, with its mcpshim link.
        XCTAssertEqual(legacy.id, first.id)
        let oldFolder = workspace.appendingPathComponent(".agents/skills/" + oldName)
        try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: oldFolder.appendingPathComponent("SKILL.md"))
        try FileManager.default.createSymbolicLink(at: oldFolder.appendingPathComponent("mcpshim"), withDestinationURL: URL(fileURLWithPath: "/bin/echo"))
        try JSONEncoder().encode([oldName]).write(to: workspace.appendingPathComponent(".agents/mcp-skills.json"))
        let notes = oldFolder.appendingPathComponent("notes.txt")
        try "Keep this".write(to: notes, atomically: true, encoding: .utf8)
        var migrated = try MCPRegistry.load(root: root)
        XCTAssertEqual(migrated.connections[0].id, first.id)
        XCTAssertEqual(migrated.assigned(to: agent).map(\.skillName), ["mcp-notion"])
        try migrated.save(root: root)
        MCPSkillWriter.removeLegacy(workspace: workspace)
        let connection = migrated.connections[0]
        ToolProviderSkills.synchronize(workspace: workspace, providers: [(ConnectionToolProvider(id: connection.skillName, title: connection.name,
            connection: connection.id) { _, _, _, _, _ in Data() }.manifest, [])])
        XCTAssertEqual(try String(contentsOf: notes), "Keep this")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: oldFolder.appendingPathComponent("mcpshim").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFolder.appendingPathComponent("SKILL.md").path))
        let skill = try String(contentsOf: workspace.appendingPathComponent(".agents/skills/mcp-notion/SKILL.md"))
        XCTAssertTrue(skill.contains("name: mcp-notion\n"))
        XCTAssertFalse(skill.contains(first.id.uuidString.lowercased()))
        XCTAssertFalse(skill.contains(first.id.uuidString.lowercased().replacingOccurrences(of: "-", with: "")))
        XCTAssertFalse(skill.contains("--connection"))
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
        MCPSkillWriter.removeLegacy(workspace: root)
        XCTAssertEqual(try String(contentsOf: file), "My own skill")
    }
}
