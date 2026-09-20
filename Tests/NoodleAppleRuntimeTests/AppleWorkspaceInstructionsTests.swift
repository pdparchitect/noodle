import XCTest
import NoodleCore
@testable import NoodleAppleRuntime

final class AppleWorkspaceInstructionsTests: XCTestCase {
    func testLoadsCompleteGeneratedInstructionsAndSkillPointers() throws {
        let root = try temporaryDirectory()
        let repository = WorkspaceRepository(rootURL: root)
        let backstory = String(repeating: "User-authored backstory. ", count: 100) + "Keep this final instruction."
        let bot = try repository.createAgent(named: "Instruction test", harnessIdentifier: "apple", backstory: backstory)
        let workspace = repository.directory(for: bot.agent)
        // Noodle writes a skill for each tool the bot may use, and AGENTS.md lists what it wrote.
        let computer = ToolProviderManifest(id: "computer", title: "Computer", summary: "Run commands in guest terminals")
        ToolProviderSkills.synchronize(workspace: workspace, providers: [(computer, [])])
        try repository.synchronizeAgentWorkspace(bot.agent)
        let generated = try String(contentsOf: workspace.appendingPathComponent("AGENTS.md"), encoding: .utf8)

        let text = try AppleWorkspaceInstructions.text(workspace: workspace)
        XCTAssertTrue(text.contains(generated), "Load the actual file without rewriting or truncating it")
        XCTAssertTrue(text.contains(backstory), "Backstory after the former 1,600-character cut-off must survive")
        XCTAssertTrue(text.contains(".agents/skills/messenger/SKILL.md"))
        XCTAssertTrue(text.contains(".agents/skills/computer/SKILL.md"))
        XCTAssertTrue(text.contains("<name>computer</name>"))
        XCTAssertTrue(text.contains("Run commands in guest terminals"), "Skill descriptions must reach the system instructions")
        XCTAssertFalse(text.contains("computer list"), "Commands belong in the skill, not the instruction loader")

        ToolProviderSkills.synchronize(workspace: workspace, providers: [])
        try repository.synchronizeAgentWorkspace(bot.agent)
        XCTAssertFalse(try AppleWorkspaceInstructions.text(workspace: workspace).contains(".agents/skills/computer/SKILL.md"),
                       "The next wake must use the current tools")
    }

    func testLoadsWorkspaceAuthoredInstructionsWithoutRequiringManagedSkillMarkers() throws {
        let root = try temporaryDirectory()
        let instructions = "# Workspace instructions\nFor this project, read .agents/skills/custom/SKILL.md.\n"
        try Data(instructions.utf8).write(to: root.appendingPathComponent("AGENTS.md"))
        XCTAssertTrue(try AppleWorkspaceInstructions.text(workspace: root).hasSuffix(instructions))
        let updated = "# Updated workspace instructions\nUse the revised project guidance.\n"
        try Data(updated.utf8).write(to: root.appendingPathComponent("AGENTS.md"))
        XCTAssertTrue(try AppleWorkspaceInstructions.text(workspace: root).hasSuffix(updated))
    }

    func testMissingInstructionsFailInsteadOfSilentlyContinuingWithoutThem() throws {
        let root = try temporaryDirectory()
        XCTAssertThrowsError(try AppleWorkspaceInstructions.text(workspace: root)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Could not load AGENTS.md"))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apple-instructions-\(UUID())")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
