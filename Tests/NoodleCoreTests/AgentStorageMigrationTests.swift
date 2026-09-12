import XCTest
@testable import NoodleCore

final class AgentStorageMigrationTests: XCTestCase {
    private var root: URL!
    private var repository: WorkspaceRepository!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        repository = WorkspaceRepository(rootURL: root, launcherExecutableURL: URL(fileURLWithPath: "/bin/echo"))
        try repository.prepare()
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func legacy() throws -> AgentRecord {
        let agent = AgentRecord(displayName: "Portable", harnessIdentifier: "codex", modelIdentifier: "fixture-model")
        let layout = repository.storage(for: agent.id)
        try FileManager.default.createDirectory(at: layout.package, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(agent).write(to: layout.configuration)
        for (path, body) in ["AGENTS.md": "Preserved backstory", "memory.md": "Durable memory",
                             "workspace/user.txt": "Existing workspace folder", "runtime/user.txt": "Existing runtime folder",
                             ".agents/skills/custom/SKILL.md": "User skill", ".noodle/inbox.json": "{\"fixture\":true}"] {
            let file = layout.package.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(body.utf8).write(to: file)
        }
        for provider in HarnessProvider.allCases {
            for extended in [false, true] {
                let name = layout.sessionState(provider: provider, extendedAccess: extended).lastPathComponent
                try Data("session pointer".utf8).write(to: layout.package.appendingPathComponent(".agents/" + name))
                try Data("unfinished token".utf8).write(to: layout.package.appendingPathComponent(".agents/" + name + ".unfinished"))
            }
        }
        try FileManager.default.createSymbolicLink(atPath: layout.package.appendingPathComponent("memory-link").path,
                                                   withDestinationPath: "memory.md")
        return agent
    }

    private func assertPreserved(_ agent: AgentRecord, file: StaticString = #filePath, line: UInt = #line) throws {
        let layout = repository.storage(for: agent.id)
        try layout.validate()
        XCTAssertEqual(try repository.loadAgents().first(where: { $0.id == agent.id })?.modelIdentifier, "fixture-model", file: file, line: line)
        for (path, body) in ["AGENTS.md": "Preserved backstory", "memory.md": "Durable memory",
                             "workspace/user.txt": "Existing workspace folder", "runtime/user.txt": "Existing runtime folder",
                             ".agents/skills/custom/SKILL.md": "User skill", ".noodle/inbox.json": "{\"fixture\":true}"] {
            XCTAssertEqual(try String(contentsOf: layout.workspace.appendingPathComponent(path)), body, file: file, line: line)
        }
        XCTAssertEqual(try String(contentsOf: layout.workspace.appendingPathComponent("memory-link")), "Durable memory", file: file, line: line)
        for provider in HarnessProvider.allCases {
            for extended in [false, true] {
                let pointer = layout.sessionState(provider: provider, extendedAccess: extended)
                XCTAssertEqual(try String(contentsOf: pointer), "session pointer", file: file, line: line)
                XCTAssertTrue(AgentTurnRecovery(sessionStateURL: pointer).hasUnfinishedTurn, file: file, line: line)
                XCTAssertFalse(AgentStorageLayout.exists(layout.workspace.appendingPathComponent(".agents/" + pointer.lastPathComponent)), file: file, line: line)
            }
        }
        XCTAssertFalse(AgentStorageLayout.exists(layout.package.appendingPathComponent(AgentStorageMigration.journalName)), file: file, line: line)
    }

    func testMigrationPreservesCoreAndAllProvidersWithoutOverwritingUserFolders() throws {
        let agent = try legacy()
        XCTAssertThrowsError(try repository.loadAgents())
        XCTAssertEqual(try repository.migrateAgentStorage(), [agent.id])
        try assertPreserved(agent)
        XCTAssertTrue(try repository.migrateAgentStorage().isEmpty)
        try assertPreserved(agent)
    }

    func testEveryMoveCanBeInterruptedAndResumed() throws {
        // Seven top-level moves, twenty session/unfinished moves, and installation.
        for interruption in 1...28 {
            let agent = try legacy()
            var moves = 0
            XCTAssertThrowsError(try AgentStorageMigration.migrate(repository.storage(for: agent.id)) {
                moves += 1
                if moves == interruption { throw CocoaError(.userCancelled) }
            })
            _ = try repository.migrateAgentStorage()
            try assertPreserved(agent)
        }
    }

    func testMalformedMetadataAndFutureLayoutsFailWithoutMovingFiles() throws {
        let agent = try legacy(), layout = repository.storage(for: agent.id)
        try Data("{\"version\":99}".utf8).write(to: layout.package.appendingPathComponent(AgentStorageLayout.markerName))
        XCTAssertThrowsError(try repository.migrateAgentStorage())
        XCTAssertEqual(try String(contentsOf: layout.package.appendingPathComponent("memory.md")), "Durable memory")
        try FileManager.default.removeItem(at: layout.package.appendingPathComponent(AgentStorageLayout.markerName))
        try Data("invalid".utf8).write(to: layout.configuration)
        XCTAssertThrowsError(try repository.migrateAgentStorage())
        XCTAssertFalse(AgentStorageLayout.exists(layout.package.appendingPathComponent(AgentStorageMigration.journalName)))
    }

    func testMigrationSeversLegacyHardLinksToAppOwnedFiles() throws {
        let agent = try legacy(), layout = repository.storage(for: agent.id)
        try FileManager.default.linkItem(at: layout.configuration, to: layout.package.appendingPathComponent("config-alias"))
        let state = layout.sessionState(provider: .codex, extendedAccess: false)
        try FileManager.default.linkItem(at: layout.package.appendingPathComponent(".agents/" + state.lastPathComponent),
                                         to: layout.package.appendingPathComponent("state-alias"))
        try repository.migrateAgentStorage()
        try Data("changed alias".utf8).write(to: layout.workspace.appendingPathComponent("config-alias"))
        try Data("changed alias".utf8).write(to: layout.workspace.appendingPathComponent("state-alias"))
        XCTAssertEqual(try repository.loadAgents().first?.id, agent.id)
        XCTAssertEqual(try String(contentsOf: state, encoding: .utf8), "session pointer")
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
        XCTAssertTrue(try destination.migrateAgentStorage().isEmpty)
        XCTAssertEqual(try destination.loadAgents(), try repository.loadAgents())
        try destination.synchronizeAgentWorkspace(created.agent)
        XCTAssertEqual(try destination.loadAgentBackstory(created.agent), "Same core")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.directory(for: created.agent)
            .appendingPathComponent(".agents/skills/messenger/messenger").path), "/bin/cat")
    }
}
