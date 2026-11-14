import XCTest
@testable import NoodleCore

final class ToolConnectionTests: XCTestCase {
    private let endpoint = URL(string: "https://mcp.notion.com/mcp")!
    func testSameURLAndNameStillHaveIndependentIdentitiesAndSkills() throws {
        let personal = try ToolConnection(name: "Notion", endpoint: endpoint)
        let work = try ToolConnection(name: "Notion", endpoint: endpoint)
        XCTAssertNotEqual(personal.id, work.id)
        XCTAssertLessThanOrEqual(personal.skillName.count, 64)
        var registry = ToolConnectionRegistry()
        registry.connections = [personal, work]
        let agent = UUID()
        try registry.assign([work.id], to: agent)
        XCTAssertEqual(registry.assigned(to: agent), [work])
        registry.remove(personal.id)
        XCTAssertEqual(registry.assigned(to: agent), [work])
        registry.remove(work.id)
        XCTAssertTrue(registry.assigned(to: agent).isEmpty)
    }
    func testATokenConnectionKeepsAValidHeaderNameAndOAuthOnesKeepNone() throws {
        XCTAssertNil(try ToolConnection(name: "Notion", endpoint: endpoint).tokenHeader)
        XCTAssertEqual(try ToolConnection(name: "VirusTotal", endpoint: endpoint, tokenHeader: " x-apikey ").tokenHeader, "x-apikey")
        for header in ["", "X Key", "X-Key:", "Host", "content-length", "Cookie", "X-Key\r\nInjected: 1"] {
            XCTAssertThrowsError(try ToolConnection(name: "Bad", endpoint: endpoint, tokenHeader: header), header)
        }
        let saved = try ToolConnection(name: "VirusTotal", endpoint: endpoint, tokenHeader: "Authorization")
        XCTAssertEqual(try JSONDecoder().decode(ToolConnection.self, from: JSONEncoder().encode(saved)), saved)
        let earlier = Data(#"{"id":"\#(UUID().uuidString)","name":"Old","endpoint":"https://mcp.notion.com/mcp","description":"","instructions":"","skillName":"mcp-old"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ToolConnection.self, from: earlier).tokenHeader)
    }

    /// The skill Noodle generates for a connection: its provider's manifest and tools, rendered.
    private func generatedSkill(_ record: ToolConnection) -> String {
        let provider = ConnectionToolProvider(id: record.skillName, title: record.name, connection: record.id,
            summary: record.description, userInstructions: record.instructions) { _, _, _, _, _ in Data() }
        return ToolProviderSkills.document(provider.manifest, tools: [])
    }
    private func provider(_ record: ToolConnection) -> (manifest: ToolProviderManifest, tools: [ToolDescriptor]) {
        (ConnectionToolProvider(id: record.skillName, title: record.name, connection: record.id, summary: record.description,
                                userInstructions: record.instructions) { _, _, _, _, _ in Data() }.manifest, [])
    }
    func testRenameDoesNotChangeSkillOrAssignment() throws {
        var record = try ToolConnection(name: "Notion Personal", endpoint: endpoint)
        let skill = record.skillName
        record.name = "New label"
        XCTAssertEqual(record.skillName, skill)
        XCTAssertFalse(generatedSkill(record).lowercased().contains(record.id.uuidString.lowercased()))
    }
    func testGeneratedSkillMetadataRespectsFormatLimits() throws {
        for name in ["🪴", "abcdefghij klmnopqrs tuvwxyz", String(repeating: "n", count: 100)] {
            let record = try ToolConnection(name: name, endpoint: endpoint, description: String(repeating: "d", count: 1000))
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
            XCTAssertThrowsError(try ToolConnection(name: "Test", endpoint: URL(string: url)!))
        }
        var registry = ToolConnectionRegistry()
        XCTAssertThrowsError(try registry.assign([UUID()], to: UUID()))
    }
    func testRegistryAndSkillLifecyclePreservesUserFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try ToolConnection(name: "Work: \"Notion\"", endpoint: endpoint,
                                            description: "Read projects\nand notes", instructions: "Only use the work account.")
        var registry = ToolConnectionRegistry()
        registry.connections = [record]
        try registry.assign([record.id], to: UUID())
        try registry.save(root: root)
        XCTAssertEqual(try ToolConnectionRegistry.load(root: root), registry)
        let workspace = root.appendingPathComponent("agent")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let skill = generatedSkill(record)
        XCTAssertTrue(skill.contains("Only use the work account."))
        XCTAssertTrue(skill.contains("messenger tool \(record.skillName) TOOL"))
        XCTAssertTrue(skill.contains("messenger tool \(record.skillName) --run FILE"))
        XCTAssertFalse(skill.contains("mcpshim"))
        XCTAssertTrue(skill.contains("mcp.call(name, input = {})"))
        XCTAssertTrue(skill.contains("tools.call(provider, name, input)"), "a connection's script can reach every other tool")
        // The scripting API is described once, by the command every skill shares.
        XCTAssertTrue(MessengerCommandKind.tool.guidance.contains("error.result"))
        XCTAssertTrue(MessengerDocumentation.skillInstructions.contains("tools.call(provider, name, input = {})"))
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
        let connection = try ToolConnection(name: "Test", endpoint: endpoint)
        ToolProviderSkills.synchronize(workspace: workspace, providers: [provider(connection)])
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
        let first = try ToolConnection(name: "Notion Work", endpoint: endpoint)
        let second = try ToolConnection(name: "Notion Personal", endpoint: endpoint)
        var registry = ToolConnectionRegistry()
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
        var registry = ToolConnectionRegistry()
        let connection = try ToolConnection(name: "Notion", endpoint: endpoint)
        registry.connections = [connection]
        try registry.save(root: root)
        let file = root.appendingPathComponent("MCP/connections.json")
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: file)
        XCTAssertThrowsError(try ToolConnectionRegistry.load(root: root))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        registry.connections = [connection, connection]
        XCTAssertThrowsError(try registry.save(root: root))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }
}
