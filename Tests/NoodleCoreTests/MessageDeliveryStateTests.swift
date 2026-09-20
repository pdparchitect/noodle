import Foundation
import NoodleCore
import XCTest

final class MessageDeliveryStateTests: XCTestCase {
    private func fixture() throws -> WorkspaceRepository {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-delivery-state-\(UUID())")
        let repository = WorkspaceRepository(rootURL: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return repository
    }

    private func deliveries(_ repository: WorkspaceRepository, _ conversation: BotConversation) throws -> [MessageDelivery] {
        try repository.loadMessages(conversationID: conversation.id).filter { $0.author == .user }.map(\.delivery)
    }

    func testUserMessageStaysQueuedUntilTheBotFetchesIt() throws {
        let repository = try fixture()
        let bot = try repository.createAgent(named: "Reader")
        let sent = try repository.sendUserMessage(conversationID: bot.conversation.id, body: "Hello")
        XCTAssertEqual(sent.delivery, .queued)

        _ = try repository.latestMessages(for: bot.agent.id, consuming: false)
        XCTAssertEqual(try deliveries(repository, bot.conversation), [.queued], "Peeking is not a pickup")

        let fetched = try repository.latestMessages(for: bot.agent.id, consuming: true)
        XCTAssertEqual(fetched.map(\.message.id), [sent.id])
        XCTAssertEqual(try deliveries(repository, bot.conversation), [.delivered])
    }

    func testFailedHandOffLeavesTheMessageQueued() throws {
        struct Refused: Error {}
        let repository = try fixture()
        let bot = try repository.createAgent(named: "Reader")
        _ = try repository.sendUserMessage(conversationID: bot.conversation.id, body: "Hello")

        XCTAssertThrowsError(try repository.latestMessages(for: bot.agent.id, consuming: true) { _ in throw Refused() })
        XCTAssertEqual(try deliveries(repository, bot.conversation), [.queued])
    }

    func testGroupMessageIsDeliveredOnceAnyMemberFetchesIt() throws {
        let repository = try fixture()
        let first = try repository.createAgent(named: "First")
        let second = try repository.createAgent(named: "Second")
        let group = try repository.createGroup(named: "Team", participantIDs: [first.agent.id, second.agent.id],
                                               existingAgents: [first.agent, second.agent])
        _ = try repository.sendUserMessage(conversationID: group.id, body: "Hello all")

        _ = try repository.latestMessages(for: first.agent.id, consuming: true)
        XCTAssertEqual(try deliveries(repository, group), [.delivered])
        XCTAssertEqual(try deliveries(repository, first.conversation), [])
    }

    func testFetchWithNothingQueuedLeavesTheTranscriptUntouched() throws {
        let repository = try fixture()
        let bot = try repository.createAgent(named: "Reader")
        _ = try repository.sendUserMessage(conversationID: bot.conversation.id, body: "Hello")
        _ = try repository.latestMessages(for: bot.agent.id, consuming: true)
        let url = repository.conversationDirectory(id: bot.conversation.id).appendingPathComponent("messages.json")
        let before = try Data(contentsOf: url)
        let stamp = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        _ = try repository.latestMessages(for: bot.agent.id, consuming: true)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, stamp)
    }
}
