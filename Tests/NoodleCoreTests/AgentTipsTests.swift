import XCTest

@testable import NoodleCore

final class AgentTipsTests: XCTestCase {
    func testEveryTipIsNamedOnceAndRenderedInTheSkill() {
        XCTAssertFalse(AgentTips.all.isEmpty)
        XCTAssertEqual(Set(AgentTips.all.map(\.id)).count, AgentTips.all.count)
        for tip in AgentTips.all {
            XCTAssertFalse(tip.title.isEmpty)
            XCTAssertFalse(tip.advice.isEmpty)
            XCTAssertTrue(AgentTips.skill.contains("## " + tip.title))
            XCTAssertTrue(AgentTips.skill.contains(tip.advice))
        }
        XCTAssertTrue(AgentTips.skill.hasPrefix("---\nname: tips\ndescription: "))
    }

    func testSandboxTipAsksTheUserForAComputer() throws {
        let tip = try XCTUnwrap(AgentTips.all.first { $0.id == "sandbox-blocked" })
        XCTAssertTrue(tip.advice.contains("assign"))
        XCTAssertTrue(tip.advice.contains("computer"))
        XCTAssertTrue(tip.advice.contains("Messenger"))
    }

    func testConnectionGuidancePointsAtTheTipsInsteadOfGivingItsOwnAdvice() throws {
        let guidance = ConnectionToolProvider.guidance(id: "mcp-notion", userInstructions: "")
        XCTAssertTrue(guidance.contains(AgentTips.reference))
        XCTAssertFalse(guidance.contains("Settings"))
        let tip = try XCTUnwrap(AgentTips.all.first { $0.id == "connection-sign-in" })
        XCTAssertTrue(tip.advice.contains("Settings → Tools"))
        XCTAssertTrue(AgentTips.reference.contains("`tips` skill"))
    }

    func testWorkspaceRefreshWritesTipsWithoutNamingThemInInstructions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = WorkspaceRepository(rootURL: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try repository.prepare()
        let agent = try repository.createAgent(named: "Tips").agent
        let workspace = repository.directory(for: agent)
        let skill = workspace.appendingPathComponent(".agents/skills/tips/SKILL.md")
        XCTAssertEqual(try String(contentsOf: skill, encoding: .utf8), AgentTips.skill)
        let instructions = try String(contentsOf: workspace.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        XCTAssertFalse(instructions.contains("tips"))
        let sandbox = try XCTUnwrap(instructions.components(separatedBy: "## Sandbox\n\n").dropFirst().first?.components(separatedBy: "\n\n").first)
        XCTAssertTrue(sandbox.contains("Shared folders"))
        XCTAssertTrue(sandbox.contains("denied"))
        XCTAssertLessThan(sandbox.count, 400)
    }

    func testUserSkillWithTheSameNameIsKept() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = WorkspaceRepository(rootURL: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try repository.prepare()
        let agent = try repository.createAgent(named: "Tips").agent
        let folder = repository.directory(for: agent).appendingPathComponent(".agents/skills/tips")
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("custom".utf8).write(to: folder.appendingPathComponent("SKILL.md"))
        try repository.synchronizeAgentWorkspace(agent)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8), "custom")
    }
}
