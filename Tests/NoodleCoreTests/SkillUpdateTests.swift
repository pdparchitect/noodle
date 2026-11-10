import XCTest
@testable import NoodleCore

/// A bot's harness session keeps the skills it read, so a bot is told once when an update changes them.
final class SkillUpdateTests: XCTestCase {
    private var root: URL!
    private var repository: WorkspaceRepository!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noodle-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func skillsDigestURL(_ agent: AgentRecord) -> URL {
        repository.storage(for: agent.id).package.appendingPathComponent("skills.sha256")
    }

    func testANewBotIsNotToldItsSkillsChanged() throws {
        let bot = try repository.createAgent(named: "Alfred").agent
        XCTAssertEqual(try repository.synchronizeAgentWorkspaces([bot]), [])
    }

    func testUnchangedSkillsTellNobody() throws {
        let bot = try repository.createAgent(named: "Alfred").agent
        _ = try repository.synchronizeAgentWorkspaces([bot])
        XCTAssertEqual(try repository.synchronizeAgentWorkspaces([bot]), [])
    }

    func testSkillsChangedByAnUpdateAreReportedOnce() throws {
        let bot = try repository.createAgent(named: "Alfred").agent
        try "an older build's skills".write(to: skillsDigestURL(bot), atomically: true, encoding: .utf8)
        XCTAssertEqual(try repository.synchronizeAgentWorkspaces([bot]), [bot.id])
        XCTAssertEqual(try repository.synchronizeAgentWorkspaces([bot]), [])
    }

    func testABotFromBeforeSkillsWereTrackedIsToldOnce() throws {
        let bot = try repository.createAgent(named: "Alfred").agent
        try FileManager.default.removeItem(at: skillsDigestURL(bot))
        XCTAssertEqual(try repository.synchronizeAgentWorkspaces([bot]), [bot.id])
        XCTAssertEqual(try repository.synchronizeAgentWorkspaces([bot]), [])
    }

    func testArchivedBotsAreNotTold() throws {
        var bot = try repository.createAgent(named: "Alfred").agent
        try "an older build's skills".write(to: skillsDigestURL(bot), atomically: true, encoding: .utf8)
        bot.archivedAt = Date()
        XCTAssertEqual(try repository.synchronizeAgentWorkspaces([bot]), [])
    }

    func testTheNoteNamesBothSkills() {
        XCTAssertTrue(AgentWake.skillsUpdatedNote.contains(".agents/skills/messenger/SKILL.md"))
        XCTAssertTrue(AgentWake.skillsUpdatedNote.contains(".agents/skills/preferences-and-memory/SKILL.md"))
    }
}
