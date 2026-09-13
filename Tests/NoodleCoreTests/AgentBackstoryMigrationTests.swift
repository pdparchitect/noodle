import XCTest
@testable import NoodleCore

final class AgentBackstoryMigrationTests: XCTestCase {
    private var root: URL!
    private var repository: WorkspaceRepository!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        repository = WorkspaceRepository(rootURL: root, discoverAppletApplication: { nil })
        try repository.prepare()
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func guide(_ backstory: String = "Original role\n\n## Working style\nBe concise.") -> String {
        """
        # Noodle Agent

        ## Backstory

        \(backstory)

        <!-- noodle:managed:start -->
        ## Noodle Runtime
        Obsolete generated instructions.
        <!-- noodle:managed:end -->

        ## Assigned computers
        More generated instructions.
        """
    }

    private func legacy(source: String?, instructions: String? = nil, flat: Bool = false) throws -> AgentRecord {
        let date = Date(timeIntervalSince1970: 100)
        let agent = AgentRecord(displayName: "Legacy", createdAt: date, updatedAt: date,
            harnessIdentifier: "codex", publicDescription: "Public description")
        let layout = repository.storage(for: agent.id)
        if flat {
            try FileManager.default.createDirectory(at: layout.package, withIntermediateDirectories: false)
        } else { try layout.create() }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(agent).write(to: layout.configuration)
        let workspace = flat ? layout.package : layout.workspace
        if let source { try Data(source.utf8).write(to: workspace.appendingPathComponent("AGENTS.md")) }
        if let instructions { try Data(instructions.utf8).write(to: workspace.appendingPathComponent("instructions.md")) }
        try Data("My preferences".utf8).write(to: workspace.appendingPathComponent("preferences.md"))
        try Data("My memory".utf8).write(to: workspace.appendingPathComponent("memory.md"))
        return agent
    }

    func testMigrationCommitsBeforeRegenerationAndDoesNotGrantLegacyAccess() throws {
        let source = guide(), agent = try legacy(source: source)
        let layout = repository.storage(for: agent.id)
        XCTAssertThrowsError(try repository.loadAgents())
        XCTAssertThrowsError(try repository.loadAgentBackstory(agent))
        XCTAssertThrowsError(try repository.synchronizeAgentWorkspace(agent))
        XCTAssertThrowsError(try repository.updateAgentBackstory(agent, backstory: "Must not bypass migration"))

        // Backstory-only migrations must not return IDs used for old access grants.
        XCTAssertTrue(try repository.migrateAgentStorage().isEmpty)
        XCTAssertEqual(try repository.loadAgents(), [agent])
        let expected = "Original role\n\n## Working style\nBe concise."
        XCTAssertEqual(try repository.loadAgentBackstory(agent), expected)
        XCTAssertEqual(try String(contentsOf: layout.workspace.appendingPathComponent("AGENTS.md"), encoding: .utf8), source)
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: layout.configuration)) as? [String: Any])
        XCTAssertEqual(config["backstory"] as? String, expected)
        XCTAssertEqual(config["displayName"] as? String, agent.displayName)
        XCTAssertNil(config["agent"], "Private configuration retains the existing flat JSON format.")

        // Simulate an interruption after the configuration commit, before sync.
        try Data("damaged output".utf8).write(to: layout.workspace.appendingPathComponent("AGENTS.md"))
        XCTAssertFalse(try AgentBackstoryMigration.migrate(layout))
        try repository.synchronizeAgentWorkspace(agent)
        let rendered = try String(contentsOf: layout.workspace.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        XCTAssertTrue(rendered.contains(expected))
        XCTAssertFalse(rendered.contains("noodle:managed:"))
        XCTAssertFalse(rendered.contains("Obsolete generated instructions"))
        XCTAssertEqual(try String(contentsOf: layout.workspace.appendingPathComponent("preferences.md"), encoding: .utf8), "My preferences")
        XCTAssertEqual(try String(contentsOf: layout.workspace.appendingPathComponent("memory.md"), encoding: .utf8), "My memory")
    }

    func testEmptyBackstoryIsACompletedMigrationAndCannotBeReimported() throws {
        let agent = try legacy(source: guide("")), layout = repository.storage(for: agent.id)
        XCTAssertTrue(try AgentBackstoryMigration.migrate(layout))
        XCTAssertEqual(try repository.loadAgentBackstory(agent), "")
        let committed = try Data(contentsOf: layout.configuration)
        try Data(guide("Injected role").utf8).write(to: layout.workspace.appendingPathComponent("AGENTS.md"))
        XCTAssertFalse(try AgentBackstoryMigration.migrate(layout))
        XCTAssertEqual(try Data(contentsOf: layout.configuration), committed)
        XCTAssertEqual(try repository.loadAgentBackstory(agent), "")
    }

    func testMigrationPreservesUnicodeAndOriginalLineEndings() throws {
        let backstory = "Research café menus.\r\n\r\n## Working style\r\nUse concise replies. 🐙"
        let source = guide().replacingOccurrences(of: "\n", with: "\r\n")
            .replacingOccurrences(of: "Original role\r\n\r\n## Working style\r\nBe concise.", with: backstory)
        let agent = try legacy(source: source)
        try repository.migrateAgentStorage()
        XCTAssertEqual(try repository.loadAgentBackstory(agent), backstory)
    }

    func testOlderBackstoryFormatsAndFlatWorkspacesMigrate() throws {
        let oldestGuide = "# Noodle Agent\n\n## Messages\nRun messenger --get-latest."
        for (source, instructions, expected) in [
            ("Custom role\nPrefer direct explanations.", nil, "Custom role\nPrefer direct explanations."),
            (nil, "# Instructions\n\nResearch carefully.\n", "Research carefully."),
            (oldestGuide, "# Instructions\n\nOriginal role", "Original role"),
            (nil, "# Instructions\n\n", "")
        ] as [(String?, String?, String)] {
            let agent = try legacy(source: source, instructions: instructions)
            try repository.migrateAgentStorage()
            XCTAssertEqual(try repository.loadAgentBackstory(agent), expected)
            try repository.synchronizeAgentWorkspace(agent)
            XCTAssertFalse(FileManager.default.fileExists(atPath: repository.directory(for: agent).appendingPathComponent("instructions.md").path))
        }
        let flat = try legacy(source: guide("Flat workspace role"), flat: true)
        XCTAssertEqual(try repository.migrateAgentStorage(), [flat.id])
        XCTAssertEqual(try repository.loadAgentBackstory(flat), "Flat workspace role")
        XCTAssertTrue(try repository.migrateAgentStorage().isEmpty)
    }

    func testDamagedLegacyGuideFailsWithoutReplacingConfigurationOrSource() throws {
        let source = guide()
        let damaged = [
            source.replacingOccurrences(of: "<!-- noodle:managed:start -->", with: ""),
            source.replacingOccurrences(of: "<!-- noodle:managed:end -->", with: ""),
            source.replacingOccurrences(of: "## Backstory", with: "## Damaged"),
            source + "\n<!-- noodle:managed:start -->",
            "# Noodle Agent\n\n## Backstory\nNo boundaries remain.",
            ""
        ].map { Data($0.utf8) } + [Data([0xFF, 0xFE])]
        for contents in damaged {
            let agent = try legacy(source: source, instructions: "Stale fallback must not override a damaged modern guide")
            let layout = repository.storage(for: agent.id), file = layout.workspace.appendingPathComponent("AGENTS.md")
            try contents.write(to: file)
            let config = try Data(contentsOf: layout.configuration)
            XCTAssertThrowsError(try AgentBackstoryMigration.migrate(layout))
            XCTAssertEqual(try Data(contentsOf: layout.configuration), config)
            XCTAssertEqual(try Data(contentsOf: file), contents)
        }
        let missing = try legacy(source: nil)
        XCTAssertThrowsError(try AgentBackstoryMigration.migrate(repository.storage(for: missing.id)))
    }

    func testFailedConfigurationCommitLeavesMigrationRetryable() throws {
        let agent = try legacy(source: guide()), layout = repository.storage(for: agent.id)
        let original = try Data(contentsOf: layout.configuration)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: layout.package.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: layout.package.path) }
        XCTAssertThrowsError(try AgentBackstoryMigration.migrate(layout))
        XCTAssertEqual(try Data(contentsOf: layout.configuration), original)
        XCTAssertEqual(try String(contentsOf: layout.workspace.appendingPathComponent("AGENTS.md"), encoding: .utf8), guide())
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: layout.package.path)
        XCTAssertTrue(try AgentBackstoryMigration.migrate(layout))
        XCTAssertFalse(try AgentBackstoryMigration.migrate(layout))
    }

    func testInvalidConfigurationDoesNotFallBackToWorkspaceMarkdown() throws {
        for invalid in [NSNull(), 42, ["unexpected": "object"]] as [Any] {
            let agent = try legacy(source: guide()), layout = repository.storage(for: agent.id)
            var config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: layout.configuration)) as? [String: Any])
            config["backstory"] = invalid
            let bytes = try JSONSerialization.data(withJSONObject: config)
            try bytes.write(to: layout.configuration)
            XCTAssertThrowsError(try AgentBackstoryMigration.migrate(layout))
            XCTAssertThrowsError(try repository.loadAgentBackstory(agent))
            XCTAssertThrowsError(try repository.synchronizeAgentWorkspace(agent))
            XCTAssertEqual(try Data(contentsOf: layout.configuration), bytes)
        }
    }

    func testLegacySourcesCannotBeReadThroughLinks() throws {
        let agent = try legacy(source: guide()), layout = repository.storage(for: agent.id)
        let file = layout.workspace.appendingPathComponent("AGENTS.md"), target = root.appendingPathComponent("private.md")
        let original = try Data(contentsOf: layout.configuration)
        try Data("Private role".utf8).write(to: target)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertThrowsError(try AgentBackstoryMigration.migrate(layout))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.linkItem(at: target, to: file)
        XCTAssertThrowsError(try AgentBackstoryMigration.migrate(layout))
        XCTAssertEqual(try Data(contentsOf: layout.configuration), original)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "Private role")
    }
}
