import XCTest
@testable import NoodleCore

final class ArchiveTests: XCTestCase {
    private var root: URL!
    private var repository: WorkspaceRepository!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-archive-tests-\(UUID())")
        repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testArchivingABotIsKeptInItsAgentFileAndSurvivesEdits() throws {
        let bot = try repository.createAgent(named: "Ada", backstory: "Keeps notes.")
        XCTAssertNil(bot.agent.archivedAt)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let archived = try repository.setAgentArchived(true, agentID: bot.agent.id, now: date)
        XCTAssertEqual(archived.archivedAt, date)

        let file = repository.storage(for: bot.agent.id).configuration
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertNotNil(json["archivedAt"])

        // An edit made from a copy loaded before archiving keeps the bot archived.
        _ = try repository.renameAgent(bot.agent, to: "Ada Lovelace")
        let reloaded = try XCTUnwrap(WorkspaceRepository(rootURL: root).loadAgents().first)
        XCTAssertEqual(reloaded.displayName, "Ada Lovelace")
        XCTAssertEqual(reloaded.archivedAt, date)
        XCTAssertEqual(try repository.loadAgentBackstory(reloaded), "Keeps notes.")

        let restored = try repository.setAgentArchived(false, agentID: bot.agent.id)
        XCTAssertNil(restored.archivedAt)
        XCTAssertNil(try repository.loadAgents().first?.archivedAt)
    }

    func testArchivingAGroupIsKeptInItsConversationFileAndSurvivesEdits() throws {
        let first = try repository.createAgent(named: "Ada"), second = try repository.createAgent(named: "Grace")
        let agents = [first.agent, second.agent]
        let group = try repository.createGroup(named: "Team", participantIDs: agents.map(\.id), existingAgents: agents)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(try repository.setConversationArchived(true, conversationID: group.id, now: date).archivedAt, date)

        _ = try repository.updateGroup(conversationID: group.id, named: "Renamed", publicDescription: nil,
                                       participantIDs: agents.map(\.id), existingAgents: agents)
        let reloaded = try XCTUnwrap(WorkspaceRepository(rootURL: root).loadConversations().first { $0.id == group.id })
        XCTAssertEqual(reloaded.displayName, "Renamed")
        XCTAssertEqual(reloaded.archivedAt, date)

        XCTAssertNil(try repository.setConversationArchived(false, conversationID: group.id).archivedAt)
    }

    func testFilesWrittenBeforeArchivingExistedLoadAsActive() throws {
        let bot = try repository.createAgent(named: "Ada")
        let file = repository.storage(for: bot.agent.id).configuration
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["archivedAt"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        XCTAssertNil(try repository.loadAgents().first?.archivedAt)
        XCTAssertNil(try repository.loadConversations().first?.archivedAt)
    }

    func testNoMessageReachesAnArchivedConversation() throws {
        let first = try repository.createAgent(named: "Ada"), second = try repository.createAgent(named: "Grace")
        let agents = [first.agent, second.agent]
        let group = try repository.createGroup(named: "Team", participantIDs: agents.map(\.id), existingAgents: agents)

        _ = try repository.setAgentArchived(true, agentID: first.agent.id)
        XCTAssertThrowsError(try repository.sendUserMessage(conversationID: first.conversation.id, body: "Hello"))
        XCTAssertThrowsError(try repository.sendAgentMessage(agentID: first.agent.id, conversationID: group.id, body: "Hi"))
        // The group still has Grace.
        _ = try repository.sendUserMessage(conversationID: group.id, body: "Hello team")
        _ = try repository.sendAgentMessage(agentID: second.agent.id, conversationID: group.id, body: "Hi")

        _ = try repository.setAgentArchived(true, agentID: second.agent.id)
        XCTAssertThrowsError(try repository.sendUserMessage(conversationID: group.id, body: "Anyone?")) {
            XCTAssertEqual($0.localizedDescription, "Every bot in this group is archived.")
        }
        _ = try repository.setAgentArchived(false, agentID: second.agent.id)

        _ = try repository.setConversationArchived(true, conversationID: group.id)
        XCTAssertThrowsError(try repository.sendUserMessage(conversationID: group.id, body: "Hello")) {
            XCTAssertEqual($0.localizedDescription, "This group is archived.")
        }
        XCTAssertThrowsError(try repository.sendAgentMessage(agentID: second.agent.id, conversationID: group.id, body: "Hi"))
        XCTAssertEqual(try repository.loadMessages(conversationID: group.id).filter { $0.author != .system }.map(\.body), ["Hello team", "Hi"])
        XCTAssertTrue(try repository.loadMessages(conversationID: first.conversation.id).filter { $0.author != .system }.isEmpty)
    }
}
