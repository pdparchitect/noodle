import XCTest
@testable import NoodleCore

final class ConversationNameTests: XCTestCase {
    func testNamesAreSingleLineAndBounded() throws {
        XCTAssertEqual(try ConversationName.validated("  Product Owner Cargio  "), "Product Owner Cargio")
        XCTAssertEqual(try ConversationName.validated("Team 🚲 — 東京"), "Team 🚲 — 東京")
        for separator in ["\n", "\r", "\r\n", "\u{2028}", "\u{2029}", "\t", "\u{0}"] {
            XCTAssertThrowsError(try ConversationName.validated("Cargio\(separator)Backstory"))
        }
        XCTAssertThrowsError(try ConversationName.validated(" \n "))
        XCTAssertNoThrow(try ConversationName.validated(String(repeating: "🚲", count: 100)))
        XCTAssertThrowsError(try ConversationName.validated(String(repeating: "a", count: 101)))
    }

    func testLegacyDisplayIsSafeWithoutChangingTheOriginal() {
        let legacy = "# Product Owner – Cargio\n\n## Backstory\nPrivate details"
        XCTAssertEqual(ConversationName.display(legacy), "# Product Owner – Cargio")
        XCTAssertEqual(ConversationName.display("\n\nTeam"), "Team")
        XCTAssertEqual(ConversationName.display("\n"), "Untitled")
        XCTAssertEqual(ConversationName.display(String(repeating: "a", count: 200)).count, 100)
        XCTAssertTrue(legacy.contains("Private details"))
    }

    func testRepositoryValidatesBotAndGroupNamesButNotMessageBodies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-name-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root, launcherExecutableURL: URL(fileURLWithPath: "/fixture/Noodle"))
        try repository.prepare()
        let invalid = "Product Owner\n## Backstory\nPrivate details"
        XCTAssertThrowsError(try repository.createAgent(named: invalid))
        let created = try repository.createAgent(named: "Cargio", backstory: invalid)
        XCTAssertThrowsError(try repository.updateAgent(created.agent, displayName: invalid,
            harnessIdentifier: nil, modelIdentifier: nil, reasoningEffort: nil))
        XCTAssertThrowsError(try repository.createGroup(named: invalid, participantIDs: [created.agent.id], existingAgents: [created.agent]))
        let group = try repository.createGroup(named: "Team", publicDescription: invalid,
            participantIDs: [created.agent.id], existingAgents: [created.agent])
        XCTAssertThrowsError(try repository.updateGroup(conversationID: group.id, named: invalid,
            publicDescription: nil, participantIDs: [created.agent.id], existingAgents: [created.agent]))
        XCTAssertEqual(try repository.loadAgents().first?.displayName, "Cargio")
        XCTAssertEqual(try repository.loadConversations().first(where: { $0.id == group.id })?.displayName, "Team")
        let body = invalid + String(repeating: " long message", count: 20)
        XCTAssertEqual(try repository.sendUserMessage(conversationID: group.id, body: body).body, body)
        XCTAssertEqual(try repository.sendAgentMessage(agentID: created.agent.id, conversationID: group.id, body: body).body, body)
        XCTAssertEqual(try repository.loadAgentBackstory(created.agent), invalid)
        XCTAssertEqual(group.publicDescription, invalid)
    }
}
