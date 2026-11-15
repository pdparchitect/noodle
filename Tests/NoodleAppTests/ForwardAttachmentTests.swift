import Foundation
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class ForwardAttachmentTests: XCTestCase {
    private func fixture() throws -> StoreFixture {
        let f = try StoreFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        return f
    }

    /// A file sent in Ada's conversation.
    private func sentFile(_ f: StoreFixture) throws -> ConversationAttachment {
        let url = f.runtime.root.appendingPathComponent("report.txt")
        try Data("Quarterly numbers".utf8).write(to: url)
        f.store.importAttachment(from: url, into: f.directA.id)
        let file = try XCTUnwrap(f.store.pendingAttachments(for: f.directA.id).last)
        f.store.sendDraft(to: f.directA.id)
        return file
    }

    func testForwardingSendsOneMessageWithACopyOfTheFileAndTheComment() throws {
        let f = try fixture(), file = try sentFile(f)
        // What is being written to Grace stays as it was.
        let staged = f.runtime.root.appendingPathComponent("staged.txt")
        try Data("Staged".utf8).write(to: staged)
        f.store.importAttachment(from: staged, into: f.directB.id)
        f.store.setDraft("Half a thought", for: f.directB.id)
        let pending = f.store.pendingAttachments(for: f.directB.id)

        let message = try f.store.forward(file, to: f.directB.id, comment: "  For the review \n")

        XCTAssertEqual(message.author, .user)
        XCTAssertEqual(message.body, "For the review")
        XCTAssertEqual(try f.repository.loadMessages(conversationID: f.directB.id).map(\.id), [message.id])
        XCTAssertEqual(f.store.messages(for: f.directB).map(\.id), [message.id])
        let copy = try XCTUnwrap(f.store.attachments(for: message).first)
        XCTAssertEqual(message.attachments, [copy.id])
        XCTAssertNotEqual(copy.id, file.id)
        XCTAssertEqual(copy.conversationID, f.directB.id)
        XCTAssertEqual(copy.originalFilename, "report.txt")
        XCTAssertEqual(copy.mediaType, file.mediaType)
        XCTAssertEqual(try Data(contentsOf: f.store.attachmentFileURL(copy)), Data("Quarterly numbers".utf8))
        // Grace hears of it; Ada's conversation and file are untouched.
        XCTAssertEqual(f.runtime.factory.processes.filter { $0.configuration.id == f.b.id }.flatMap(\.notifications), [false])
        XCTAssertEqual(try f.repository.loadMessages(conversationID: f.directA.id).count, 1)
        XCTAssertEqual(try Data(contentsOf: f.store.attachmentFileURL(file)), Data("Quarterly numbers".utf8))
        XCTAssertEqual(f.store.draft(for: f.directB.id), "Half a thought")
        XCTAssertEqual(f.store.pendingAttachments(for: f.directB.id), pending)
    }

    func testForwardingWithoutACommentSaysWhatWasSent() throws {
        let f = try fixture(), file = try sentFile(f), group = try f.group()
        let message = try f.store.forward(file, to: group.id, comment: " \n ")
        XCTAssertEqual(message.body, "Sent 1 attachment")
        XCTAssertEqual(f.store.attachments(for: message).map(\.originalFilename), ["report.txt"])
    }

    func testOnlyFilesCanBeForwardedAndOnlyToAConversationThatExists() throws {
        let f = try fixture(), file = try sentFile(f)
        XCTAssertTrue(file.isForwardable)
        XCTAssertThrowsError(try f.store.forward(file, to: UUID(), comment: "Hi"))
        let link = try f.repository.importLinkAttachment(try XCTUnwrap(URL(string: "https://example.com")), into: f.directA.id)
        XCTAssertFalse(link.isForwardable)
        XCTAssertThrowsError(try f.store.forward(link, to: f.directB.id, comment: "Hi"))
        let audio = f.runtime.root.appendingPathComponent("recording.caf")
        try Data([0, 1, 2, 3]).write(to: audio)
        let voice = VoiceMessage(transcript: "A note", duration: 2, waveform: [0.5], localeIdentifier: "en-GB")
        XCTAssertFalse(try f.repository.importAttachment(
            from: audio, into: f.directA.id, mediaType: "audio/x-caf", voice: voice).isForwardable)
        XCTAssertTrue(f.store.messages(for: f.directB).isEmpty)
    }

    func testTheSheetListsOtherBotsAndGroupsThatCanTakeMessagesAndSearchesTheirNames() throws {
        let f = try fixture(), group = try f.group(name: "Project")
        let ids = { (search: String) in AttachmentForwarding.targets(in: f.store, from: f.directA.id, search: search).map(\.id) }
        XCTAssertEqual(Set(ids("")), [f.directB.id, group.id])
        XCTAssertEqual(ids(" proj "), [group.id])
        XCTAssertEqual(ids("grace"), [f.directB.id])
        XCTAssertEqual(ids("Nobody"), [])
        // An archived bot takes no messages; the group still has Ada.
        XCTAssertTrue(f.store.setArchived(true, agentID: f.b.id))
        XCTAssertEqual(ids(""), [group.id])
    }

    /// Dragging a file out of a conversation onto another one in the sidebar sends it there at once, as Forward… does.
    func testDroppingAFileFromAConversationOnAnotherSendsItThere() async throws {
        let f = try fixture(), file = try sentFile(f), group = try f.group()
        f.store.selectedConversationID = f.directA.id
        f.store.setDraft("Half a thought", for: f.directB.id)

        XCTAssertTrue(f.store.drop([f.store.attachmentDragProvider(file)], onConversation: f.directB.id))
        try await waitUntil { !f.store.messages(for: f.directB).isEmpty }
        let message = try XCTUnwrap(f.store.messages(for: f.directB).last)
        XCTAssertEqual(message.author, .user)
        XCTAssertEqual(message.body, "Sent 1 attachment")
        let copy = try XCTUnwrap(f.store.attachments(for: message).first)
        XCTAssertNotEqual(copy.id, file.id)
        XCTAssertEqual(try Data(contentsOf: f.store.attachmentFileURL(copy)), Data("Quarterly numbers".utf8))
        XCTAssertEqual(f.store.draft(for: f.directB.id), "Half a thought")
        XCTAssertTrue(f.store.pendingAttachments(for: f.directB.id).isEmpty, "sent, not staged")
        XCTAssertEqual(f.store.selectedConversationID, f.directA.id, "the conversation in front stays")

        XCTAssertTrue(f.store.drop([f.store.attachmentDragProvider(file)], onConversation: group.id))
        try await waitUntil { !f.store.messages(for: group).isEmpty }
        XCTAssertEqual(f.store.attachments(for: try XCTUnwrap(f.store.messages(for: group).last)).map(\.originalFilename), ["report.txt"])
    }

    /// A file from elsewhere, such as the Finder, opens the conversation it was dropped on with the file ready to send.
    func testDroppingAnyOtherFileOnAConversationStagesItThere() async throws {
        let f = try fixture()
        f.store.selectedConversationID = f.directA.id
        let url = f.runtime.root.appendingPathComponent("notes.txt")
        try Data("Notes".utf8).write(to: url)
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: url))

        XCTAssertTrue(f.store.drop([provider], onConversation: f.directB.id))
        try await waitUntil { !f.store.pendingAttachments(for: f.directB.id).isEmpty }
        XCTAssertEqual(f.store.pendingAttachments(for: f.directB.id).map(\.originalFilename), ["notes.txt"])
        XCTAssertEqual(f.store.selectedConversationID, f.directB.id)
        XCTAssertTrue(f.store.messages(for: f.directB).isEmpty)
    }

    func testAFileDroppedOnItsOwnOrAClosedConversationIsNotSent() async throws {
        let f = try fixture(), file = try sentFile(f)
        XCTAssertTrue(f.store.setArchived(true, agentID: f.b.id))
        XCTAssertFalse(f.store.drop([f.store.attachmentDragProvider(file)], onConversation: f.directB.id))
        XCTAssertFalse(f.store.drop([], onConversation: f.directA.id))
        _ = f.store.drop([f.store.attachmentDragProvider(file)], onConversation: f.directA.id)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(f.store.messages(for: f.directA).count, 1)
        XCTAssertTrue(f.store.pendingAttachments(for: f.directA.id).isEmpty)
        XCTAssertTrue(f.store.messages(for: f.directB).isEmpty)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(15))
        while !condition() {
            guard ContinuousClock.now < end else { XCTFail("The drop did not finish"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
