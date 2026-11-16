import Foundation
@testable import NoodleCore
import XCTest
@testable import NoodleRuntimeSettings

/// What counts as arriving between two reads of the transcripts, in every app: bots' new messages, oldest first,
/// and new reactions; never the person's messages or the app's own notices. A reaction wakes every other member.
final class TranscriptArrivalsTests: XCTestCase {
    func testOnlyBotsNewMessagesArrive() {
        let conversation = UUID(), bot = UUID()
        let old = ChatMessage(conversationID: conversation, author: .agent(bot), body: "Old.", delivery: .delivered)
        let later = ChatMessage(conversationID: conversation, author: .agent(bot), body: "Later.",
                                createdAt: Date(timeIntervalSinceNow: 10), delivery: .delivered)
        let sooner = ChatMessage(conversationID: conversation, author: .agent(bot), body: "Sooner.", delivery: .delivered)
        let person = ChatMessage(conversationID: conversation, author: .user, body: "Hi.", delivery: .delivered)
        let notice = ChatMessage(conversationID: conversation, author: .system, body: "Lead changed.", delivery: .delivered)

        let arrivals = TranscriptArrivals(before: [old], after: [old, later, person, notice, sooner])
        XCTAssertEqual(arrivals.messages.map(\.body), ["Sooner.", "Later."])
        XCTAssertTrue(TranscriptArrivals(before: [old], after: [old, person, notice]).isEmpty)
    }

    func testAReactionWakesEveryOtherMember() {
        let conversation = UUID(), first = UUID(), second = UUID()
        let group = BotConversation(id: conversation, displayName: "Team", kind: .group, participantIDs: [first, second])
        var message = ChatMessage(conversationID: conversation, author: .agent(first), body: "Done.", delivery: .delivered)
        let before = message
        message.reactionChanges = [
            MessageReactionChange(id: UUID(), conversationID: conversation, messageID: message.id, sequence: 1,
                                  author: .agent(second), emoji: "👍", removed: false, createdAt: Date())
        ]
        let byBot = TranscriptArrivals(before: [before], after: [message])
        XCTAssertTrue(byBot.messages.isEmpty)
        XCTAssertEqual(byBot.reactionRecipientIDs(in: [group]), [first])

        var byPerson = message
        byPerson.reactionChanges = [
            MessageReactionChange(id: UUID(), conversationID: conversation, messageID: message.id, sequence: 1,
                                  author: .user, emoji: "👍", removed: false, createdAt: Date())
        ]
        XCTAssertEqual(TranscriptArrivals(before: [before], after: [byPerson]).reactionRecipientIDs(in: [group]), [first, second])
        XCTAssertTrue(TranscriptArrivals(before: [byPerson], after: [byPerson]).isEmpty, "Seen before")
    }
}
