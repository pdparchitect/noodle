import Foundation
import NoodleCore
import XCTest

/// What every front end shows of a conversation, the Mac's and Windows's alike, worked out once in NoodleCore.
final class ConversationPresentationTests: XCTestCase {
    private let ada = AgentRecord(displayName: "Ada\nLovelace", harnessIdentifier: "codex")
    private let grace = AgentRecord(displayName: "Grace", harnessIdentifier: "codex")

    private func archived(_ agent: AgentRecord) -> AgentRecord {
        var agent = agent
        agent.archivedAt = Date()
        return agent
    }

    func testADirectConversationIsNamedAfterItsBotAndAGroupAfterItself() {
        let direct = BotConversation(displayName: "Old name", kind: .direct, participantIDs: [ada.id])
        let group = BotConversation(displayName: "Design\nteam", kind: .group, participantIDs: [ada.id, grace.id])
        XCTAssertEqual(direct.title(among: [grace, ada]), "Ada")
        XCTAssertEqual(group.title(among: [grace, ada]), "Design")
        // A bot that is gone leaves the conversation's own name.
        XCTAssertEqual(direct.title(among: [grace]), "Old name")
    }

    func testArchivedBotsLeaveAGroupsMembersUnlessEveryOneIs() {
        let group = BotConversation(displayName: "Team", kind: .group, participantIDs: [ada.id, grace.id])
        XCTAssertEqual(group.participants(among: [grace, ada]).map(\.id), [ada.id, grace.id])
        XCTAssertEqual(group.shownParticipants(among: [archived(ada), grace]).map(\.id), [grace.id])
        XCTAssertEqual(group.shownParticipants(among: [archived(ada), archived(grace)]).map(\.id), [ada.id, grace.id])
        let direct = BotConversation(displayName: "Ada", kind: .direct, participantIDs: [ada.id])
        XCTAssertEqual(direct.shownParticipants(among: [archived(ada)]).map(\.id), [ada.id])
    }

    func testTheLastMessageDatesAConversationNotItsLastEdit() {
        let created = Date(timeIntervalSince1970: 1_000), said = Date(timeIntervalSince1970: 2_000)
        var conversation = BotConversation(displayName: "Ada", kind: .direct, participantIDs: [ada.id], createdAt: created)
        conversation.updatedAt = Date(timeIntervalSince1970: 3_000)
        XCTAssertEqual(conversation.lastMessageDate(in: []), created)
        let message = ChatMessage(conversationID: conversation.id, author: .user, body: "Hi", createdAt: said, delivery: .queued)
        XCTAssertEqual(conversation.lastMessageDate(in: [message]), said)
    }

    func testAGuestsConversationIsNotShownHere() {
        var conversation = BotConversation(displayName: "Ada", kind: .direct, participantIDs: [ada.id])
        XCTAssertTrue(conversation.isShownHere)
        conversation.guest = ConversationGuest(id: UUID(), name: "Linus")
        XCTAssertFalse(conversation.isShownHere)
    }

    func testATranscriptOpensOnItsNewestPageAndAddsAPageAtTheTop() {
        let conversation = UUID()
        let messages = (0..<250).map { ChatMessage(conversationID: conversation, author: .user, body: "\($0)", delivery: .queued) }
        let first = TranscriptPaging.firstShown(in: messages, firstShownID: nil, reading: nil)
        XCTAssertEqual(first, 150)
        XCTAssertEqual(TranscriptPaging.firstShown(in: messages, firstShownID: nil, reading: messages[120].id), 120)
        let before = TranscriptPaging.pageBefore(first, in: messages)
        XCTAssertEqual(before, messages[50].id)
        XCTAssertEqual(TranscriptPaging.firstShown(in: messages, firstShownID: before, reading: nil), 50)
        XCTAssertEqual(TranscriptPaging.pageBefore(50, in: messages), messages[0].id)
    }

    func testThePersonsMessageSaysHowFarItGot() {
        XCTAssertEqual([MessageDelivery.saved, .queued, .delivered, .failed].map(\.title),
                       ["Saved", "Sent", "Delivered", "Not delivered"])
    }

    func testNothingCanBeSentToAnArchivedBotOrGroup() {
        let direct = BotConversation(displayName: "Grace", kind: .direct, participantIDs: [grace.id])
        XCTAssertNil(ComposerAvailability.unavailableReason(for: direct, members: [grace], member: "bot"))
        XCTAssertEqual(ComposerAvailability.unavailableReason(for: direct, members: [archived(grace)], member: "bot"),
                       "Grace is archived")
        let group = BotConversation(displayName: "Team", kind: .group, participantIDs: [ada.id, grace.id])
        XCTAssertEqual(ComposerAvailability.unavailableReason(for: group, members: [archived(ada), archived(grace)], member: "bot"),
                       "Every bot in this group is archived")
    }
}
