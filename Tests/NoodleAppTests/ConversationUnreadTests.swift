import Foundation
import HubLink
import NoodleCore
import XCTest
@testable import NoodleRuntimeSettings

/// Which conversations wait for the person, in every app: a bot's message makes its conversation unread unless it
/// is being looked at, a message naming the person marks it mentioned, reading clears both, and the Dock counts
/// muted groups never and mentions-only groups once named.
final class ConversationUnreadTests: XCTestCase {
    private func message(_ conversation: UUID, _ body: String, from author: MessageAuthor = .agent(UUID())) -> ChatMessage {
        ChatMessage(conversationID: conversation, author: author, body: body, delivery: .delivered)
    }

    func testMessagesMakeConversationsUnreadAndMentionedUntilRead() {
        let quiet = UUID(), named = UUID(), viewed = UUID(), muted = UUID()
        var unread = ConversationUnread()
        let seen = unread.register([message(quiet, "Done."), message(named, "Over to you, Avery."), message(viewed, "Done."),
                                    message(muted, "Done.")],
                                   isViewing: { $0 == viewed }, mentionName: { _ in "Avery Lin" })
        XCTAssertEqual(seen, [viewed])
        XCTAssertEqual(unread.unread, [quiet, named, muted])
        XCTAssertEqual(unread.mentioned, [named])
        let levels: [UUID: LinkNotifications] = [named: .mentions, quiet: .mentions, muted: .muted]
        XCTAssertEqual(unread.badged { levels[$0] ?? .all }, [named])
        XCTAssertTrue(unread.markRead(named))
        XCTAssertFalse(unread.markRead(named))
        XCTAssertEqual(unread.unread, [quiet, muted])
        XCTAssertTrue(unread.mentioned.isEmpty)
    }

    func testItIsKeptInTheRepository() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Unread-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let a = UUID(), b = UUID()
        var unread = ConversationUnread()
        _ = unread.register([message(a, "Hi Avery"), message(b, "Hi")], isViewing: { _ in false }, mentionName: { _ in "Avery" })
        try unread.save(to: repository)
        let loaded = ConversationUnread(repository: repository, known: [a])
        XCTAssertEqual(loaded.unread, [a], "Conversations that no longer exist are dropped")
        XCTAssertEqual(loaded.mentioned, [a])
    }
}
