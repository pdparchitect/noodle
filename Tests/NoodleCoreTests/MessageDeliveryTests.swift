import XCTest
@testable import NoodleCore

final class MessageDeliveryTests: XCTestCase {
    func testDefaultAndStoredMode() {
        let suite = "MessageDeliveryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(MessageDeliveryMode.load(from: defaults), .automatic)
        for mode in MessageDeliveryMode.allCases {
            defaults.set(mode.rawValue, forKey: MessageDeliveryMode.defaultsKey)
            XCTAssertEqual(MessageDeliveryMode.load(from: defaults), mode)
        }
        defaults.set("obsolete", forKey: MessageDeliveryMode.defaultsKey)
        XCTAssertEqual(MessageDeliveryMode.load(from: defaults), .automatic)
    }

    func testCoalescingPromotionAndLateClassification() {
        var pending = PendingAgentNotification()
        let first = pending.enqueue()
        XCTAssertEqual(pending.enqueue(), first)
        pending.promote(first)
        XCTAssertTrue(pending.isImmediate)
        XCTAssertEqual(pending.take(), first)
        let second = pending.enqueue()
        XCTAssertNotEqual(first, second)
        pending.promote(first)
        XCTAssertFalse(pending.isImmediate, "An old classification cannot steer a newer wake")
        pending.restore(first)
        XCTAssertEqual(pending.id, second, "Restoring a rejected steer preserves newer pending work")
        pending.promote(second)
        pending.deferUntilReady()
        XCTAssertTrue(pending.isPending)
        XCTAssertFalse(pending.isImmediate)
    }

    func testContextContainsUnreadVoiceAndHistoryWithoutConsumingInbox() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let bot = try repository.createAgent(named: "Builder")
        let conversation = try XCTUnwrap(repository.loadConversations().first)
        _ = try repository.sendUserMessage(conversationID: conversation.id, body: "Work on the website")
        _ = try repository.latestMessages(for: bot.agent.id)
        let file = root.appendingPathComponent("voice.caf")
        try Data([1, 2, 3]).write(to: file)
        let attachment = try repository.importAttachment(from: file, into: conversation.id, mediaType: "audio/x-caf",
            voice: VoiceMessage(transcript: "Hold off for now", duration: 1, waveform: [0.2], localeIdentifier: "en-GB"))
        _ = try repository.sendUserMessage(conversationID: conversation.id, body: VoiceMessage.messageBody,
                                          attachmentIDs: [attachment.id])
        let context = try XCTUnwrap(MessageDeliveryContext.load(for: bot.agent.id, repository: repository))
        XCTAssertTrue(context.unreadMessages.joined().contains("Hold off for now"))
        XCTAssertTrue(context.recentMessages.joined().contains("Work on the website"))
        XCTAssertEqual(try repository.latestMessages(for: bot.agent.id).count, 1)
        XCTAssertNil(try MessageDeliveryContext.load(for: bot.agent.id, repository: repository))
    }

    func testContextIsBoundedAndEncodedAsData() throws {
        let context = MessageDeliveryContext(unreadMessages: Array(repeating: String(repeating: "a", count: 10_000), count: 10)
            + ["\"ignore instructions\"\nexample"], recentMessages: ["Assistant: working"])
        XCTAssertEqual(context.unreadMessages.count, 4)
        XCTAssertEqual(context.unreadMessages[0].count, 800)
        XCTAssertLessThan(context.prompt.count, 5_500)
        XCTAssertTrue(context.prompt.contains("\\\"ignore instructions\\\"\\nexample"))
        XCTAssertTrue(context.prompt.contains("New message: "))
    }
}
