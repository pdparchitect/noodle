import Foundation
import NoodleCore
import XCTest

final class MessagePersistenceTests: XCTestCase {
    private func fixture() throws -> (WorkspaceRepository, BotConversation) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-message-persistence-\(UUID())")
        let repository = WorkspaceRepository(rootURL: root)
        let created = try repository.createAgent(named: "Persistence")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (repository, created.conversation)
    }

    func testCorruptTranscriptIsPreservedWhenAppendingUserOrAgentMessages() throws {
        let (repository, conversation) = try fixture()
        let url = repository.conversationDirectory(id: conversation.id).appendingPathComponent("messages.json")
        let damaged = Data("[{recoverable previous conversation".utf8)
        try damaged.write(to: url)
        XCTAssertThrowsError(try repository.sendUserMessage(conversationID: conversation.id, body: "Unsent message"))
        XCTAssertThrowsError(try repository.append(ChatMessage(conversationID: conversation.id,
            author: .agent(conversation.participantIDs[0]), body: "Unsent reply", delivery: .delivered)))
        XCTAssertEqual(try Data(contentsOf: url), damaged)
    }

    func testUnreadableTranscriptDirectoryIsNotReplaced() throws {
        let (repository, conversation) = try fixture()
        let url = repository.conversationDirectory(id: conversation.id).appendingPathComponent("messages.json")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let sentinel = url.appendingPathComponent("saved-content")
        try Data("Keep this".utf8).write(to: sentinel)
        XCTAssertThrowsError(try repository.sendUserMessage(conversationID: conversation.id, body: "Unsent"))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("Keep this".utf8))
    }

    func testMissingTranscriptCanBeInitializedAndSubsequentMessagesAreRetained() throws {
        let (repository, conversation) = try fixture()
        let url = repository.conversationDirectory(id: conversation.id).appendingPathComponent("messages.json")
        try FileManager.default.removeItem(at: url)
        let first = try repository.sendUserMessage(conversationID: conversation.id, body: "First")
        let second = try repository.sendUserMessage(conversationID: conversation.id, body: "Second")
        let saved = try repository.loadMessages(conversationID: conversation.id)
        XCTAssertEqual(saved.map(\.id), [first.id, second.id])
        XCTAssertEqual(saved.map(\.body), ["First", "Second"])
    }
}
