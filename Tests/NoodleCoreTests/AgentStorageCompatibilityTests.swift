import XCTest
@testable import NoodleCore

/// What Noodle still guarantees about bot packages now that the 0.13.0 and 0.14.0 migrations are
/// gone: older and damaged packages are refused everywhere and never rewritten.
final class AgentStorageCompatibilityTests: XCTestCase {
    private var root: URL!
    private var repository: WorkspaceRepository!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        repository = WorkspaceRepository(rootURL: root, launcherExecutableURL: URL(fileURLWithPath: "/bin/echo"), discoverAppletApplication: { nil })
        try repository.prepare()
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    /// A current package whose configuration predates the stored backstory.
    private func withoutBackstory() throws -> AgentRecord {
        let agent = AgentRecord(displayName: "Legacy", harnessIdentifier: "codex")
        let layout = repository.storage(for: agent.id)
        try layout.create()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(agent).write(to: layout.configuration)
        try Data("# Noodle Agent\n\n## Backstory\n\nOriginal role\n".utf8).write(to: layout.workspace.appendingPathComponent("AGENTS.md"))
        return agent
    }

    private func message(_ body: () throws -> Void) -> String {
        do { try body(); return "" } catch { return error.localizedDescription }
    }

    func testAFlatWorkspaceIsRefusedWithTheReleaseThatUpgradesIt() throws {
        let agent = AgentRecord(displayName: "Flat", harnessIdentifier: "codex")
        let layout = repository.storage(for: agent.id)
        try FileManager.default.createDirectory(at: layout.package, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(agent).write(to: layout.configuration)
        try Data("Durable memory".utf8).write(to: layout.package.appendingPathComponent("memory.md"))
        XCTAssertTrue(message { _ = try repository.loadAgents() }.contains("0.13.0"))
        XCTAssertThrowsError(try repository.synchronizeAgentWorkspace(agent))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: layout.package.path).sorted(), ["agent.json", "memory.md"])
    }

    func testAPackageWithoutAStoredBackstoryIsRefusedEverywhere() throws {
        let agent = try withoutBackstory(), layout = repository.storage(for: agent.id)
        let original = try Data(contentsOf: layout.configuration)
        XCTAssertTrue(message { _ = try repository.loadAgents() }.contains("0.14.0"))
        XCTAssertThrowsError(try repository.loadAgentBackstory(agent))
        XCTAssertThrowsError(try repository.synchronizeAgentWorkspace(agent))
        XCTAssertThrowsError(try repository.updateAgentBackstory(agent, backstory: "Must not bypass the upgrade"))
        XCTAssertEqual(try Data(contentsOf: layout.configuration), original)
    }

    func testAnInvalidStoredBackstoryDoesNotFallBackToWorkspaceMarkdown() throws {
        for invalid in [NSNull(), 42, ["unexpected": "object"]] as [Any] {
            let agent = try withoutBackstory(), layout = repository.storage(for: agent.id)
            var config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: layout.configuration)) as? [String: Any])
            config["backstory"] = invalid
            let bytes = try JSONSerialization.data(withJSONObject: config)
            try bytes.write(to: layout.configuration)
            XCTAssertThrowsError(try repository.loadAgentBackstory(agent))
            XCTAssertThrowsError(try repository.synchronizeAgentWorkspace(agent))
            XCTAssertEqual(try Data(contentsOf: layout.configuration), bytes)
        }
    }

    func testAFutureLayoutIsRefused() throws {
        let created = try repository.createAgent(named: "Future"), layout = repository.storage(for: created.agent.id)
        try Data("{\"version\":99}".utf8).write(to: layout.package.appendingPathComponent(AgentStorageLayout.markerName))
        XCTAssertTrue(message { _ = try repository.loadAgents() }.contains("storage version 99"))
    }

    func testRedirectedWorkspaceAndIdentityMismatchAreRejected() throws {
        let created = try repository.createAgent(named: "New")
        let layout = repository.storage(for: created.agent.id)
        try FileManager.default.removeItem(at: layout.workspace)
        try FileManager.default.createSymbolicLink(at: layout.workspace, withDestinationURL: root)
        XCTAssertThrowsError(try repository.loadAgents())
        XCTAssertThrowsError(try repository.synchronizeAgentWorkspace(created.agent))
        try FileManager.default.removeItem(at: layout.workspace)
        try FileManager.default.createDirectory(at: layout.workspace, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: layout.package, to: repository.agentsURL.appendingPathComponent(UUID().uuidString.lowercased()))
        XCTAssertThrowsError(try repository.loadAgents())
    }

    func testCopiedPackageIsDiscoveredAndManagedLinksRefresh() throws {
        let created = try repository.createAgent(named: "Copy", backstory: "Same core")
        let destination = WorkspaceRepository(rootURL: root.appendingPathComponent("Destination"), launcherExecutableURL: URL(fileURLWithPath: "/bin/cat"))
        try destination.prepare()
        try FileManager.default.copyItem(at: repository.storage(for: created.agent.id).package,
                                         to: destination.storage(for: created.agent.id).package)
        XCTAssertEqual(try destination.loadAgents(), try repository.loadAgents())
        try destination.synchronizeAgentWorkspace(created.agent)
        XCTAssertEqual(try destination.loadAgentBackstory(created.agent), "Same core")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.directory(for: created.agent)
            .appendingPathComponent(".agents/skills/messenger/messenger").path), "/bin/cat")
    }
}
