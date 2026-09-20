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
        XCTAssertTrue(document.hasPrefix("---\nname: vision\ndescription: Read text from images. Tools: ocr.\n---\n"), document)
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
