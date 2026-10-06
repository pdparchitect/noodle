import AppKit
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle

@MainActor final class MessageTableBubbleTests: HiddenViewTests {
    private func bubble(_ body: String, in f: StoreFixture) -> NSHostingView<some View> {
        let message = ChatMessage(conversationID: f.directA.id, author: .agent(f.a.id), body: body, delivery: .delivered)
        return host(MessageBubble(message: message, hasConversationBackground: false,
            selectedAttachmentID: .constant(nil), previewAttachment: { _, _ in }, showAgentProfile: nil)
            .padding().environment(f.store))
    }

    private func shows(_ text: String, in root: NSView) -> Bool {
        elements(root).contains { labels($0).contains(text) }
    }

    private let daily = "Daily numbers:\n\n| Day | Messages |\n|---|---|\n"
        + (1...24).map { "| Sep \($0) | \($0) |" }.joined(separator: "\n")
        + "\n\nWant this as a CSV?"

    func testTableRendersAsAFoldedSortableGridWithoutCountingAsLongText() async throws {
        let f = try fixture()
        let view = bubble(daily, in: f)
        let sort = try await control("Sort by Messages", in: view)
        XCTAssertEqual(elements(view).filter { self.matches("Sort by Day", node: $0) }.count, 1)
        XCTAssertTrue(hasControl("18 more rows", in: view))
        XCTAssertFalse(hasControl("Read full message", in: view))
        XCTAssertTrue(shows("Daily numbers:", in: view))
        XCTAssertTrue(shows("Want this as a CSV?", in: view))
        XCTAssertFalse(shows("| Day | Messages |", in: view))
        XCTAssertTrue(shows("Sep 6", in: view))
        XCTAssertFalse(shows("Sep 7", in: view))

        press(sort)
        press(try await control("Sort by Messages", in: view))
        // Rows animate into their new order.
        try await wait { self.shows("Sep 24", in: view) && !self.shows("Sep 1", in: view) }
        XCTAssertTrue(shows("Sep 19", in: view))
        XCTAssertFalse(shows("Sep 18", in: view))
    }

    func testMoreRowsOpensTheWholeTable() async throws {
        let f = try fixture()
        NSApplication.shared.setActivationPolicy(.accessory)
        let view = bubble(daily, in: f)
        let window = try XCTUnwrap(view.window)
        window.setFrameOrigin(.init(x: 80, y: 80))
        window.orderFront(nil)
        press(try await control("18 more rows", in: view))
        var reader: NSView?
        try await wait {
            reader = NSApp.windows.filter { $0.isVisible && $0 !== window }
                .compactMap(\.contentView).first { self.shows("Sep 24", in: $0) }
            return reader != nil
        }
        let content = try XCTUnwrap(reader)
        XCTAssertTrue(shows("Sep 1", in: content))
        XCTAssertTrue(hasControl("Sort by Messages", in: content))
        press(try await control("Close", in: content))
        try await wait { content.window?.isVisible != true }
        window.close()
    }

    func testLongProseBesideATableStillFolds() async throws {
        let f = try fixture()
        let prose = (1...20).map { "Finding \($0)." }.joined(separator: "\n")
        let view = bubble(prose + "\n\n| A | B |\n|---|---|\n| 1 | 2 |", in: f)
        _ = try await control("Read full message", in: view)
        XCTAssertTrue(hasControl("Sort by A", in: view))
        XCTAssertFalse(hasControl("more rows", in: view))
    }

    func testMessagesWithoutTablesHaveNoTableControls() async throws {
        let f = try fixture()
        let view = bubble("Plain reply with a | pipe.\n---", in: f)
        try await wait { self.shows("Plain reply with a | pipe.\n---", in: view) }
        XCTAssertFalse(elements(view).contains { labels($0).contains { $0.hasPrefix("Sort by") } })
    }

    func testNotificationsAndPreviewsLeaveTablesOut() throws {
        let f = try fixture()
        let body = "Here you go:\n\n| Day | Messages |\n|---|---|\n| Sep 1 | 4 |\n\nAll **quiet**."
        let message = ChatMessage(conversationID: f.directA.id, author: .agent(f.a.id), body: body, delivery: .delivered)
        XCTAssertEqual(NoodleNotifications.content(message: message, from: f.a, in: f.directA).body,
                       "Here you go:\n\nAll **quiet**.")
        let tableOnly = ChatMessage(conversationID: f.directA.id, author: .agent(f.a.id),
                                    body: "| A |\n|---|\n| 1 |", delivery: .delivered)
        XCTAssertEqual(NoodleNotifications.content(message: tableOnly, from: f.a, in: f.directA).body, "Sent a table")

        _ = try f.repository.sendUserMessage(conversationID: f.directB.id, body: body)
        f.store.refreshTranscripts()
        XCTAssertEqual(f.store.preview(for: f.directB), "Here you go: All quiet.")
    }
}
