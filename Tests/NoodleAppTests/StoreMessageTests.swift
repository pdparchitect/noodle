import Foundation
import NoodleCore
import Observation
import XCTest
@testable import Noodle

@MainActor final class StoreMessageTests: XCTestCase {
    private func fixture() throws -> StoreFixture {
        let f = try StoreFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        return f
    }
    private func attachment(_ f: StoreFixture, name: String = "sample.txt") throws -> ConversationAttachment {
        let url = f.runtime.root.appendingPathComponent(name)
        try Data("Fixture bytes".utf8).write(to: url)
        f.store.importAttachment(from: url, into: f.directA.id)
        return try XCTUnwrap(f.store.pendingAttachments(for: f.directA.id).last)
    }

    func testAttachmentOnlySendsHaveCorrectLabelsAndCannotBeResent() throws {
        for count in [1, 2] {
            let f = try fixture()
            let attachments = try (0..<count).map { try attachment(f, name: "file\($0).txt") }
            f.store.setDraft(" \n ", for: f.directA.id)
            f.store.sendDraft(to: f.directA.id)
            let message = try XCTUnwrap(f.store.messages(for: f.directA).last)
            XCTAssertEqual(message.body, count == 1 ? "Sent 1 attachment" : "Sent 2 attachments")
            XCTAssertEqual(message.attachments, attachments.map(\.id))
            XCTAssertTrue(f.store.pendingAttachments(for: f.directA.id).isEmpty)
            XCTAssertTrue(f.store.draft(for: f.directA.id).isEmpty)
            f.store.sendDraft(to: f.directA.id)
            XCTAssertEqual(try f.repository.loadMessages(conversationID: f.directA.id).map(\.id), [message.id])
            XCTAssertEqual(f.runtime.factory.processes.last?.notifications, [false])
        }
    }

    func testFailedSendPreservesDraftAndAttachmentAndDoesNotWakeBot() throws {
        let f = try fixture(), file = try attachment(f)
        f.store.setDraft("Keep this unsent text", for: f.directA.id)
        let messages = f.repository.conversationDirectory(id: f.directA.id).appendingPathComponent("messages.json")
        try Data("corrupt transcript".utf8).write(to: messages)
        f.store.sendDraft(to: f.directA.id)
        XCTAssertNotNil(f.store.errorMessage)
        XCTAssertEqual(f.store.draft(for: f.directA.id), "Keep this unsent text")
        XCTAssertEqual(f.store.pendingAttachments(for: f.directA.id).map(\.id), [file.id])
        XCTAssertEqual(try Data(contentsOf: f.store.attachmentFileURL(file)), Data("Fixture bytes".utf8))
        XCTAssertTrue(f.store.messages(for: f.directA).isEmpty)
        XCTAssertTrue(f.runtime.factory.processes.isEmpty)
        XCTAssertEqual(try Data(contentsOf: messages), Data("corrupt transcript".utf8))
    }

    func testCommandAndVoiceSendKeepExistingComposerDrafts() throws {
        let f = try fixture(), file = try attachment(f)
        f.store.setDraft("Still editing", for: f.directA.id)
        f.store.selectedConversationID = f.directB.id
        let command = try f.store.sendCommand("/status", to: f.directA.id)
        let audio = f.runtime.root.appendingPathComponent("recording.caf")
        try Data([0, 1, 2, 3]).write(to: audio)
        let voice = VoiceMessage(transcript: "A spoken note", duration: 2, waveform: [0.2, 0.8], localeIdentifier: "en-GB")
        try f.store.sendVoiceMessage(from: audio, voice: voice, to: f.directA.id)
        let messages = try f.repository.loadMessages(conversationID: f.directA.id)
        XCTAssertEqual(messages.map(\.body), [command.body, VoiceMessage.messageBody])
        let sentVoice = try XCTUnwrap(f.store.attachments(for: messages[1]).first)
        XCTAssertEqual(sentVoice.voice, voice)
        XCTAssertEqual(f.store.draft(for: f.directA.id), "Still editing")
        XCTAssertEqual(f.store.pendingAttachments(for: f.directA.id).map(\.id), [file.id])
        XCTAssertEqual(f.store.selectedConversationID, f.directB.id)
        XCTAssertTrue(f.store.messages(for: f.directB).isEmpty)
    }

    func testMissingConversationAndEmptyCommandsNeverPublishMessages() throws {
        let f = try fixture()
        XCTAssertThrowsError(try f.store.sendCommand("/status", to: UUID()))
        XCTAssertThrowsError(try f.store.sendCommand(" \n ", to: f.directA.id))
        let voice = VoiceMessage(transcript: nil, duration: 1, waveform: [], localeIdentifier: nil)
        XCTAssertThrowsError(try f.store.sendVoiceMessage(from: f.runtime.root, voice: voice, to: UUID()))
        XCTAssertTrue(f.store.messages(for: f.directA).isEmpty)
        XCTAssertTrue(f.runtime.factory.processes.isEmpty)
    }

    func testReactionTogglesUsePersistedStateDespiteAStaleMessageSnapshot() throws {
        let f = try fixture()
        let message = try f.repository.sendUserMessage(conversationID: f.directA.id, body: "React here")
        try f.repository.setReaction(conversationID: f.directA.id, messageID: message.id, author: .agent(f.a.id), emoji: "👍", present: true)
        f.store.refreshTranscripts()
        f.store.toggleReaction("👍", on: message)
        XCTAssertEqual(f.store.messages(for: f.directA).last?.reactions?.count, 2)
        f.store.toggleReaction("👍", on: message)
        let reactions = try XCTUnwrap(f.store.messages(for: f.directA).last?.reactions)
        XCTAssertEqual(reactions.count, 1)
        XCTAssertEqual(reactions[0].author, .agent(f.a.id))
        XCTAssertEqual(reactions[0].emoji, "👍")
    }

    func testChangingReactionPreservesExistingReplacementAndOtherAuthors() throws {
        let f = try fixture()
        let message = try f.repository.sendUserMessage(conversationID: f.directA.id, body: "React here")
        for emoji in ["👍", "🎉"] {
            try f.repository.setReaction(conversationID: f.directA.id, messageID: message.id, author: .user, emoji: emoji, present: true)
        }
        try f.repository.setReaction(conversationID: f.directA.id, messageID: message.id, author: .agent(f.a.id), emoji: "👍", present: true)
        f.store.changeReaction("👍", to: "🎉", on: message)
        let reactions = try XCTUnwrap(f.store.messages(for: f.directA).last?.reactions)
        XCTAssertEqual(reactions.count, 2)
        XCTAssertEqual(reactions.filter { $0.author == .user }.map(\.emoji), ["🎉"])
        XCTAssertEqual(reactions.filter { $0.author == .agent(f.a.id) }.map(\.emoji), ["👍"])
        f.store.removeReaction("🎉", on: message)
        XCTAssertEqual(f.store.messages(for: f.directA).last?.reactions?.count, 1)
    }

    func testInvalidReactionReplacementPreservesOriginalReaction() throws {
        let f = try fixture()
        let message = try f.repository.sendUserMessage(conversationID: f.directA.id, body: "React here")
        try f.repository.setReaction(conversationID: f.directA.id, messageID: message.id, author: .user, emoji: "👍", present: true)
        f.store.refreshTranscripts()
        f.store.changeReaction("👍", to: "", on: message)
        XCTAssertNotNil(f.store.errorMessage)
        XCTAssertEqual(try f.repository.loadMessages(conversationID: f.directA.id).last?.reactions?.map(\.emoji), ["👍"])
    }

    func testUnreadStatePersistsAndReadingIsNotUndoneByAnUnchangedRefresh() throws {
        let f = try fixture()
        let reply = ChatMessage(conversationID: f.directB.id, author: .agent(f.b.id), body: "New reply", delivery: .delivered)
        try f.repository.append(reply)
        f.store.refreshTranscripts()
        XCTAssertTrue(f.store.hasUnreadMessages(in: f.directB))
        XCTAssertEqual(try f.repository.loadUnreadConversationIDs(), [f.directB.id])
        f.store.markConversationRead(f.directB.id)
        f.store.refreshTranscripts()
        XCTAssertFalse(f.store.hasUnreadMessages(in: f.directB))
        XCTAssertTrue(try f.repository.loadUnreadConversationIDs().isEmpty)
        try f.repository.saveUnreadConversationIDs([f.directA.id, UUID()])
        f.store.reload()
        XCTAssertEqual(f.store.unreadConversationIDs, [f.directA.id])
        XCTAssertEqual(try f.repository.loadUnreadConversationIDs(), [f.directA.id])
        f.store.markConversationRead(nil)
        XCTAssertTrue(f.store.hasUnreadMessages(in: f.directA))
    }

    func testInteractingWithAnAlreadyReadConversationDoesNotInvalidateUnreadObservers() throws {
        let f = try fixture()
        withObservationTracking {
            _ = f.store.unreadConversationIDs
        } onChange: {
            XCTFail("Repeated input in a read conversation must not refresh unread indicators")
        }
        for _ in 0..<10 { f.store.markConversationRead(f.directA.id) }
    }
}
