import XCTest
@testable import NoodleCore

final class ToolProviderSkillsTests: XCTestCase {
    private struct Fixture: ToolProvider {
        let kind = ToolProviderKind.appExtension
        let manifest: ToolProviderManifest
        func tools(context: ToolCallContext) async throws -> Data {
            Data("""
            {"tools":[{"name":"ocr","description":"Recognize text.","inputSchema":{"type":"object","required":["image"],"properties":{
              "image":{"type":"string","format":"noodle-file","description":"Image file."},
              "languages":{"type":"array","items":{"type":"string"},"description":"Preferred languages."},
              "fast":{"type":"boolean"}}}}]}
            """.utf8)
        }
        func call(_ tool: String, arguments: Data, files: [ToolFile], context: ToolCallContext) async throws -> Data { Data("{}".utf8) }
    }
    private final class Assignments: @unchecked Sendable {
        private let lock = NSLock(); private var values: ToolAssignments = .none
        var value: ToolAssignments { get { lock.withLock { values } } set { lock.withLock { values = newValue } } }
    }

    private var workspace: URL!
    private let registry = ToolProviderRegistry()
    private let assignments = Assignments()
    private var broker: ToolBridgeBroker!
    private let vision = ToolProviderManifest(id: "vision", title: "Vision", summary: "Read text\nfrom images.", instructions: "Images stay on this Mac.")

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        broker = ToolBridgeBroker(registry: registry) { [assignments] _ in assignments.value }
    }
    override func tearDown() { broker.stop(); try? FileManager.default.removeItem(at: workspace) }

    private func skill(_ name: String) -> String? {
        try? String(contentsOf: workspace.appendingPathComponent(".agents/skills/\(name)/SKILL.md"), encoding: .utf8)
    }
    private func wait(_ message: String, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertTrue(condition(), message)
    }

    func testDocumentTeachesTheCommandOptionsAndProviderGuidance() async throws {
        let tools = try ToolDescriptor.list(mcp: try await Fixture(manifest: vision).tools(context: .init(agentID: UUID(), workspace: workspace)))
        let document = ToolProviderSkills.document(vision, tools: tools)
        XCTAssertTrue(document.hasPrefix("---\nname: vision\ndescription: \"Read text from images. Tools: ocr.\"\n---\n"), document)
        let tricky = ToolProviderSkills.document(.init(id: "x", title: "T", summary: "Say \"hi\": now " + String(repeating: "d", count: 2000)), tools: tools)
        let header = try XCTUnwrap(tricky.split(separator: "\n").first { $0.hasPrefix("description: ") })
        let decoded = try JSONDecoder().decode(String.self, from: Data(header.dropFirst(13).utf8))
        XCTAssertTrue(decoded.hasPrefix("Say \"hi\": now "))
        XCTAssertLessThanOrEqual(decoded.count, 1024)
        for expected in ["# Vision", "./.agents/skills/messenger/messenger tool vision TOOL", "Images stay on this Mac.", "### ocr", "Recognize text.",
                         "`--image FILE` (required) — Image file.", "`--languages VALUE` (repeatable) — Preferred languages.", "`--fast`"] {
            XCTAssertTrue(document.contains(expected), "Missing \(expected) in:\n\(document)")
        }
    }

    func testSkillsFollowRegistrationAssignmentAndRemoval() throws {
        try registry.register(Fixture(manifest: vision))
        try registry.register(Fixture(manifest: .init(id: "browser", title: "Browser", summary: "Browse.", activation: .whenAssigned("browser"))))
        try broker.start(agents: [ToolBridgeAgent(id: UUID(), workspace: workspace)])
        wait("An always-on provider gets a skill at start.") { skill("vision") != nil }
        XCTAssertNil(skill("browser"))

        assignments.value = ["browser": ["b1"]]
        broker.synchronizeSkills()
        wait("An assigned provider gets a skill.") { skill("browser") != nil }

        try registry.register(Fixture(manifest: .init(id: "late", title: "Late", summary: "Registered after start.")))
        wait("Discovery after start writes the skill without a restart.") { skill("late") != nil }

        registry.unregister("vision")
        assignments.value = [:]
        broker.synchronizeSkills()
        wait("Removed and unassigned providers lose their skills.") { skill("vision") == nil && skill("browser") == nil }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".agents/skills/vision").path))
        XCTAssertNotNil(skill("late"))
    }

    func testTheAppHearsWhenABotsGeneratedSkillsChangeAndOnlyThen() throws {
        let changes = Counter(), agent = UUID()
        broker.onSkillsChanged = { id in if id == agent { changes.increment() } }
        try registry.register(Fixture(manifest: vision))
        try broker.start(agents: [ToolBridgeAgent(id: agent, workspace: workspace)])
        wait("The first skill is a change.") { changes.value == 1 }
        broker.synchronizeSkills()
        broker.synchronizeSkills()
        try registry.register(Fixture(manifest: .init(id: "late", title: "Late", summary: "Registered after start.")))
        wait("A new provider is a change.") { changes.value == 2 }
        XCTAssertEqual(changes.value, 2, "rewriting identical skills is not a change")
    }
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    /// A tool connection that needs sign-in, or a server that is down, cannot list its tools.
    func testAProviderThatCannotListItsToolsStillGetsItsSkillAndKeepsTheLastGoodOne() throws {
        final class Flaky: ToolProvider, @unchecked Sendable {
            let kind = ToolProviderKind.connection
            let manifest = ToolProviderManifest(id: "mcp-notion", title: "Notion", summary: "Wiki.", instructions: "Ask the user to reconnect in Settings if sign-in is needed.")
            private let lock = NSLock(); private var failing = true
            var fails: Bool { get { lock.withLock { failing } } set { lock.withLock { failing = newValue } } }
            func tools(context: ToolCallContext) async throws -> Data {
                if fails { throw ToolProviderError("Reconnect Notion in Settings.") }
                return Data(#"{"tools":[{"name":"search","description":"Search pages."}]}"#.utf8)
            }
            func call(_ tool: String, arguments: Data, files: [ToolFile], context: ToolCallContext) async throws -> Data { Data("{}".utf8) }
        }
        let provider = Flaky()
        try registry.register(provider)
        try broker.start(agents: [ToolBridgeAgent(id: UUID(), workspace: workspace)])
        wait("The skill exists even though the tools cannot be listed yet.") { skill("mcp-notion") != nil }
        XCTAssertTrue(skill("mcp-notion")?.contains("Ask the user to reconnect") == true)
        XCTAssertFalse(skill("mcp-notion")?.contains("### search") == true)

        provider.fails = false
        broker.synchronizeSkills()
        wait("Once the tools can be listed they appear.") { skill("mcp-notion")?.contains("### search") == true }
        let good = skill("mcp-notion")
        provider.fails = true
        broker.synchronizeSkills()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(skill("mcp-notion"), good, "a temporary failure does not erase what the bot already knows")

        // A rename or new guidance must still reach the bot while the tools cannot be listed.
        let renamed = ToolProviderManifest(id: "mcp-notion", title: "Company wiki", summary: "Wiki.", instructions: "Ask the user to reconnect in Settings if sign-in is needed.")
        ToolProviderSkills.synchronize(workspace: workspace, listed: [(renamed, nil)])
        XCTAssertTrue(skill("mcp-notion")?.contains("# Company wiki") == true)
        XCTAssertFalse(skill("mcp-notion")?.contains("# Notion") == true)
    }

    func testAUsersOwnSkillWithTheSameNameIsNeverReplacedOrRemoved() throws {
        let folder = workspace.appendingPathComponent(".agents/skills/vision")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: folder.appendingPathComponent("SKILL.md"))
        try registry.register(Fixture(manifest: vision))
        try registry.register(Fixture(manifest: .init(id: "other", title: "Other", summary: "")))
        try broker.start(agents: [ToolBridgeAgent(id: UUID(), workspace: workspace)])
        wait("Other providers still get their skills.") { skill("other") != nil }
        XCTAssertEqual(skill("vision"), "mine")
        registry.unregister("vision")
        wait("Sync ran again.") { skill("other") != nil }
        XCTAssertEqual(skill("vision"), "mine")
    }
}

/// A bot's AGENTS.md names the tools Noodle generated skills for, whatever they are.
final class ToolInstructionsTests: XCTestCase {
    private var root: URL!
    private var repository: WorkspaceRepository!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        repository = WorkspaceRepository(rootURL: root)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testGeneratedSkillsAreListedAndNothingElseIsNamed() throws {
        let bot = try repository.createAgent(named: "Tools")
        let workspace = repository.directory(for: bot.agent)
        func guide() throws -> String { try String(contentsOf: workspace.appendingPathComponent("AGENTS.md"), encoding: .utf8) }
        XCTAssertFalse(try guide().contains("## Tools"))

        // Assignments alone name nothing: only a skill Noodle generated from a provider is listed.
        var browsers = BrowserAssignments(); browsers.agents[bot.agent.id.uuidString] = [UUID()]; try browsers.save(root: root)
        var computers = ComputerAssignments(); computers.agents[bot.agent.id.uuidString] = [UUID()]; try computers.save(root: root)
        try repository.synchronizeAgentWorkspace(bot.agent)
        let assigned = try guide()
        XCTAssertFalse(assigned.contains("skills/browser") || assigned.contains("skills/computer"), assigned)

        let mine = workspace.appendingPathComponent(".agents/skills/mine")
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        try Data("---\nname: mine\ndescription: My own skill.\n---\n".utf8).write(to: mine.appendingPathComponent("SKILL.md"))
        ToolProviderSkills.synchronize(workspace: workspace, providers: [
            (ToolProviderManifest(id: "vision", title: "Vision", summary: "Read text from images."), []),
            (ToolProviderManifest(id: "telescope", title: "Telescope", summary: "Point at\nthe sky."), [])])
        XCTAssertEqual(ToolProviderSkills.generated(workspace: workspace).map(\.name), ["telescope", "vision"])
        try repository.synchronizeAgentWorkspace(bot.agent)
        let listed = try guide()
        XCTAssertTrue(listed.contains("## Tools"))
        XCTAssertTrue(listed.contains("- `.agents/skills/vision/SKILL.md`: Read text from images. Tools: ."), listed)
        XCTAssertTrue(listed.contains("- `.agents/skills/telescope/SKILL.md`: Point at the sky."), listed)
        XCTAssertFalse(listed.contains("skills/mine"), "a bot's own skills are its business")

        ToolProviderSkills.synchronize(workspace: workspace, providers: [])
        try repository.synchronizeAgentWorkspace(bot.agent)
        XCTAssertFalse(try guide().contains("## Tools"))
    }
}

/// Workspaces written by earlier versions carry a hand-written browser skill, its command
/// link and a request mailbox. They go; a generated skill of the same name stays.
final class BrowserLegacyCleanupTests: XCTestCase {
    private var workspace: URL!
    private var folder: URL { workspace.appendingPathComponent(".agents/skills/browser") }

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent(".noodle/browser-bridge"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: workspace.appendingPathComponent(".noodle/browser-bridge/session.json"))
        try WorkspaceMailbox.synchronizeSkill(workspace: workspace, name: "browser", enabled: true, instructions: "old",
                                              command: "browser", executable: URL(fileURLWithPath: "/usr/bin/true"))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: workspace) }

    func testTheOldSkillItsCommandLinkAndMailboxAreRemoved() {
        BrowserAgentSkill.removeLegacy(workspace: workspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".noodle/browser-bridge").path))
        BrowserAgentSkill.removeLegacy(workspace: workspace)
    }

    func testAGeneratedSkillKeepsItsTextAndLosesOnlyTheStaleCommandLink() throws {
        ToolProviderSkills.synchronize(workspace: workspace, providers: [(ToolProviderManifest(id: "browser", title: "Noodle Browser", summary: "Browse."), [])])
        let generated = try String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8)
        XCTAssertTrue(generated.contains("messenger tool browser"))
        BrowserAgentSkill.removeLegacy(workspace: workspace)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8), generated)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: folder.appendingPathComponent("browser").path))
    }

    func testAUsersOwnBrowserSkillIsLeftAlone() throws {
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: folder.appendingPathComponent("SKILL.md"))
        BrowserAgentSkill.removeLegacy(workspace: workspace)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8), "mine")
    }
}
