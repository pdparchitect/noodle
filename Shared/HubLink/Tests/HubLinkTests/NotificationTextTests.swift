import HubLink
import XCTest

/// Notifications take plain text only, so bot Markdown is turned into clean words there.
final class NotificationTextTests: XCTestCase {
    private func text(_ body: String) -> String { MessageSegment.notificationText(body) }

    func testEmphasisAndInlineCodeLoseTheirMarks() {
        XCTAssertEqual(text("Will, **the slot and `/workspace/diego-pk2` are yours now.** Nothing of mine runs there."),
                       "Will, the slot and /workspace/diego-pk2 are yours now. Nothing of mine runs there.")
        XCTAssertEqual(text("_Quietly_ done, ~~maybe~~ surely."), "Quietly done, maybe surely.")
    }

    func testLinksShowTheirText() {
        XCTAssertEqual(text("See [the pull request](https://example.com/pr/42) for details."), "See the pull request for details.")
    }

    func testHeadingsAndQuotesKeepTheirWords() {
        XCTAssertEqual(text("# Plan\n\n> Ship it on Friday."), "Plan\nShip it on Friday.")
    }

    func testListsKeepTheirShape() {
        XCTAssertEqual(text("Here's what I'll do:\n1. **No more cascading.** Instead\n2. One pass\n\n- tidy\n* test"),
                       "Here's what I'll do:\n1. No more cascading. Instead\n2. One pass\n• tidy\n• test")
    }

    func testCodeBlocksAreLeftOut() {
        XCTAssertEqual(text("Run this:\n\n```sh\nmake **all**\n```\n\nThen wait."), "Run this:\nThen wait.")
        XCTAssertEqual(text("```\nonly code\n```"), "Sent code")
    }

    func testPlainTextIsLeftAsItIs() {
        XCTAssertEqual(text("Dinner at eight, 2 * 3 = 6."), "Dinner at eight, 2 * 3 = 6.")
        XCTAssertEqual(text("Line one\nline two"), "Line one\nline two")
    }

    func testTablesStillBecomeTheirText() {
        XCTAssertEqual(text("| A | B |\n|---|---|\n| 1 | 2 |"), "Sent a table")
    }
}
