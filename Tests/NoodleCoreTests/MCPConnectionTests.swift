import XCTest
@testable import NoodleCore

final class MCPConnectionTests: XCTestCase {
    private let endpoint = URL(string: "https://mcp.notion.com/mcp")!
    func testSameURLAndNameStillHaveIndependentIdentitiesAndSkills() throws {
        let personal = try MCPConnectionRecord(name: "Notion", endpoint: endpoint)
        let work = try MCPConnectionRecord(name: "Notion", endpoint: endpoint)
        XCTAssertNotEqual(personal.id, work.id)
        XCTAssertLessThanOrEqual(personal.skillName.count, 64)
        var registry = MCPRegistry()
        registry.connections = [personal, work]
        let agent = UUID()
        try registry.assign([work.id], to: agent)
        XCTAssertEqual(registry.assigned(to: agent), [work])
        registry.remove(personal.id)
        XCTAssertEqual(registry.assigned(to: agent), [work])
        registry.remove(work.id)
        XCTAssertTrue(registry.assigned(to: agent).isEmpty)
    }
    /// The skill Noodle generates for a connection: its provider's manifest and tools, rendered.
    private func generatedSkill(_ record: MCPConnectionRecord) -> String {
        let provider = ConnectionToolProvider(id: record.skillName, title: record.name, connection: record.id,
            summary: record.description, userInstructions: record.instructions) { _, _, _, _, _ in Data() }
        return ToolProviderSkills.document(provider.manifest, tools: [])
    }
    private func provider(_ record: MCPConnectionRecord) -> (manifest: ToolProviderManifest, tools: [ToolDescriptor]) {
        (ConnectionToolProvider(id: record.skillName, title: record.name, connection: record.id, summary: record.description,
                                userInstructions: record.instructions) { _, _, _, _, _ in Data() }.manifest, [])
    }
    func testRenameDoesNotChangeSkillOrAssignment() throws {
        var record = try MCPConnectionRecord(name: "Notion Personal", endpoint: endpoint)
        let skill = record.skillName
        record.name = "New label"
        XCTAssertEqual(record.skillName, skill)
        XCTAssertFalse(generatedSkill(record).lowercased().contains(record.id.uuidString.lowercased()))
    }
    func testGeneratedSkillMetadataRespectsFormatLimits() throws {
        for name in ["🪴", "abcdefghij klmnopqrs tuvwxyz", String(repeating: "n", count: 100)] {
            let record = try MCPConnectionRecord(name: name, endpoint: endpoint, description: String(repeating: "d", count: 1000))
            XCTAssertFalse(record.skillName.contains("--"))
            XCTAssertLessThanOrEqual(record.skillName.count, 64)
            let line = try XCTUnwrap(generatedSkill(record).components(separatedBy: "\n").first { $0.hasPrefix("description: ") })
            let description = try JSONDecoder().decode(String.self, from: Data(line.dropFirst("description: ".count).utf8))
            XCTAssertFalse(description.isEmpty)
            XCTAssertLessThanOrEqual(description.count, 1024)
        }
    }
    func testRejectInvalidEndpointsAndAssignments() throws {
        for url in ["http://mcp.notion.com/mcp", "https://localhost/mcp", "https://10.0.0.1/mcp",
                    "https://user:password@example.com/mcp", "file:///tmp/server", "https://example.com/mcp#fragment"] {
            XCTAssertThrowsError(try MCPConnectionRecord(name: "Test", endpoint: URL(string: url)!))
        }
        var registry = MCPRegistry()
        XCTAssertThrowsError(try registry.assign([UUID()], to: UUID()))
    }
    func testRegistryAndSkillLifecyclePreservesUserFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try MCPConnectionRecord(name: "Work: \"Notion\"", endpoint: endpoint,
                                            description: "Read projects\nand notes", instructions: "Only use the work account.")
        var registry = MCPRegistry()
        registry.connections = [record]
        try registry.assign([record.id], to: UUID())
        try registry.save(root: root)
        XCTAssertEqual(try MCPRegistry.load(root: root), registry)
        let workspace = root.appendingPathComponent("agent")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        // What an earlier Noodle wrote: a hand-written skill, its mcpshim link, the list that tracked it and a mailbox.
        let directory = workspace.appendingPathComponent(".agents/skills/\(record.skillName)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent(".noodle/mcp-bridge"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: directory.appendingPathComponent("SKILL.md"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("mcpshim"), withDestinationURL: URL(fileURLWithPath: "/bin/echo"))
        try JSONEncoder().encode([record.skillName]).write(to: workspace.appendingPathComponent(".agents/mcp-skills.json"))
        let userFile = directory.appendingPathComponent("my-notes.txt")
        try "Keep me".write(to: userFile, atomically: true, encoding: .utf8)
        MCPSkillWriter.removeLegacy(workspace: workspace)
        XCTAssertEqual(try String(contentsOf: userFile, encoding: .utf8), "Keep me")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("SKILL.md").path))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: directory.appendingPathComponent("mcpshim").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".agents/mcp-skills.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".noodle/mcp-bridge").path))

        let skill = generatedSkill(record)
        XCTAssertTrue(skill.contains("Only use the work account."))
        XCTAssertTrue(skill.contains("messenger tool \(record.skillName) TOOL"))
        XCTAssertTrue(skill.contains("messenger tool \(record.skillName) --run FILE"))
        XCTAssertFalse(skill.contains("mcpshim"))
        XCTAssertTrue(skill.contains("mcp.call(name, input = {})"))
        XCTAssertTrue(skill.contains("error.result"))
        XCTAssertFalse(skill.contains("--connection"))
        XCTAssertFalse(skill.contains(record.id.uuidString.lowercased()))
        XCTAssertFalse(skill.contains(record.id.uuidString.lowercased().replacingOccurrences(of: "-", with: "")))
    }
    func testRedirectedSkillDirectoryIsNotWritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent(".agents"), withDestinationURL: outside)
        let connection = try MCPConnectionRecord(name: "Test", endpoint: endpoint)
        ToolProviderSkills.synchronize(workspace: workspace, providers: [provider(connection)])
        MCPSkillWriter.removeLegacy(workspace: workspace)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
    func testBridgeRefusesSymlinksAndOversizedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try MCPBridgeFiles.prepare(workspace: root)
        let file = directory.appendingPathComponent("test")
        try Data(repeating: 1, count: 10).write(to: file)
        XCTAssertThrowsError(try MCPBridgeFiles.read(file, limit: 9))
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try MCPBridgeFiles.read(link, limit: 20))
    }
    func testFullSizeArgumentsFitTheEnvelope() throws {
        let arguments = Data(repeating: 65, count: MCPBridgeFiles.maxRequestBytes)
        let request = MCPBridgeRequest(session: String(repeating: "a", count: 72), connectionID: UUID(),
            action: .call, tool: String(repeating: "t", count: 1024), arguments: arguments)
        let data = try JSONEncoder().encode(request)
        XCTAssertLessThanOrEqual(data.count, MCPBridgeFiles.maxRequestEnvelopeBytes)
        XCTAssertEqual(try JSONDecoder().decode(MCPBridgeRequest.self, from: data).arguments, arguments)
    }
    func testResourceReadBridgeEncodingAndLegacyRequests() throws {
        let request = MCPBridgeRequest(session: "fixture", connectionID: UUID(), action: .readResource,
            tool: nil, arguments: nil, uri: "reports://file")
        let roundTrip = try JSONDecoder().decode(MCPBridgeRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(roundTrip.action, .readResource)
        XCTAssertEqual(roundTrip.uri, "reports://file")
        let legacy = MCPBridgeRequest(session: "fixture", connectionID: UUID(), action: .call, tool: "echo", arguments: Data("{}".utf8))
        let encoded = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("\"uri\""))
        XCTAssertNil(try JSONDecoder().decode(MCPBridgeRequest.self, from: encoded).uri)
    }
    func testBootstrapIndexesOnlyAssignedAccountsAndPreservesBackstory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        let agent = try repository.createAgent(named: "Test", backstory: "Private instructions").agent
        let first = try MCPConnectionRecord(name: "Notion Work", endpoint: endpoint)
        let second = try MCPConnectionRecord(name: "Notion Personal", endpoint: endpoint)
        var registry = MCPRegistry()
        registry.connections = [first, second]
        try registry.assign([first.id], to: agent.id)
        try registry.save(root: root)
        // The app's broker generates a skill for each granted connection; the bot's instructions list those.
        ToolProviderSkills.synchronize(workspace: repository.directory(for: agent), providers: [provider(first)])
        try repository.synchronizeAgentWorkspace(agent)
        let instructions = try String(contentsOf: repository.directory(for: agent).appendingPathComponent("AGENTS.md"), encoding: .utf8)
        XCTAssertTrue(instructions.contains(first.skillName + "/SKILL.md"))
        XCTAssertFalse(instructions.contains(second.skillName))
        XCTAssertEqual(try repository.loadAgentBackstory(agent), "Private instructions")
        try registry.assign([], to: agent.id)
        try registry.save(root: root)
        ToolProviderSkills.synchronize(workspace: repository.directory(for: agent), providers: [])
        try repository.synchronizeAgentWorkspace(agent)
        let updated = try String(contentsOf: repository.directory(for: agent).appendingPathComponent("AGENTS.md"), encoding: .utf8)
        XCTAssertFalse(updated.contains(first.skillName))
    }
    func testCorruptRegistryFailsWithoutReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var registry = MCPRegistry()
        let connection = try MCPConnectionRecord(name: "Notion", endpoint: endpoint)
        registry.connections = [connection]
        try registry.save(root: root)
        let file = root.appendingPathComponent("MCP/connections.json")
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: file)
        XCTAssertThrowsError(try MCPRegistry.load(root: root))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        registry.connections = [connection, connection]
        XCTAssertThrowsError(try registry.save(root: root))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }
}
