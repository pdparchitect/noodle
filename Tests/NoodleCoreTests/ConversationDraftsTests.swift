import XCTest
@testable import NoodleCore

final class ConversationDraftsTests: XCTestCase {
    func testSwitchingBetweenDirectAndGroupDraftsPreservesExactText() {
        var drafts = ConversationDrafts()
        let direct = UUID(), group = UUID(), empty = UUID()
        let text = "Unfinished @Mara\n  with spacing 🙂 "
        drafts[direct].text = text
        XCTAssertTrue(drafts[group].isEmpty)
        drafts[group].text = "A separate group reply"
        XCTAssertTrue(drafts[empty].isEmpty)
        XCTAssertEqual(drafts[direct].text, text)
        XCTAssertEqual(drafts[group].text, "A separate group reply")
    }

    func testClearingSentDraftDoesNotClearAnotherChat() {
        var drafts = ConversationDrafts()
        let first = UUID(), second = UUID()
        drafts[first].text = "Send this"
        drafts[first].attachments = [attachment(in: first)]
        drafts[second].text = "Keep this"
        drafts.clear(first)
        XCTAssertTrue(drafts[first].isEmpty)
        XCTAssertEqual(drafts[second].text, "Keep this")
        XCTAssertTrue(drafts.hasContent)
        drafts[second].text = ""
        XCTAssertFalse(drafts.hasContent)
    }

    func testAttachmentsStayWithTheirDestinationIncludingLateImports() {
        var drafts = ConversationDrafts()
        let original = UUID(), other = UUID()
        let image = attachment(in: original)
        drafts[original].text = "Here is the image"
        drafts[other].text = "Currently selected"
        // An asynchronous import finishes after the user selects another chat.
        drafts[original].attachments.append(image)
        XCTAssertEqual(drafts[original].attachments, [image])
        XCTAssertTrue(drafts[other].attachments.isEmpty)
        drafts[original].attachments.removeAll { $0.id == image.id }
        XCTAssertEqual(drafts[original].text, "Here is the image")
    }

    func testReloadPreservesExistingDraftsAndDropsDeletedConversations() {
        var drafts = ConversationDrafts()
        let kept = UUID(), deleted = UUID()
        drafts[kept].text = "Still editing"
        drafts[deleted].text = "Deleted chat"
        drafts.retainConversations([kept])
        XCTAssertEqual(drafts[kept].text, "Still editing")
        XCTAssertTrue(drafts[deleted].isEmpty)
    }

    func testAttachmentOnlyDraftAlsoPreventsAutomaticRelaunch() {
        var drafts = ConversationDrafts()
        let conversation = UUID()
        XCTAssertFalse(drafts.hasContent)
        drafts[conversation].attachments.append(attachment(in: conversation))
        XCTAssertTrue(drafts.hasContent)
        drafts.clear(conversation)
        XCTAssertFalse(drafts.hasContent)
    }

    private func attachment(in conversationID: UUID) -> ConversationAttachment {
        ConversationAttachment(
            conversationID: conversationID,
            originalFilename: "image.png",
            storedFilename: "image.png",
            mediaType: "image/png",
            byteCount: 42
        )
    }
}
