import XCTest
@testable import NoodleCore

final class MarkdownPlainTextTests: XCTestCase {
    func testFormattingAndLinksBecomePlainVisibleText() {
        let markdown = "Done — [whetstone](</Users/pdp/Library/Containers/example>) with **three files** and `git`."

        XCTAssertEqual(
            MarkdownPlainText.convert(markdown),
            "Done — whetstone with three files and git."
        )
    }

    func testBlockMarkupAndWhitespaceAreRemovedFromPreview() {
        let markdown = """
        ## Result

        - First item
        - Second *item*
        """

        XCTAssertEqual(MarkdownPlainText.convert(markdown), "Result First item Second item")
    }

    func testPlainTextIsPreservedAndCompacted() {
        XCTAssertEqual(
            MarkdownPlainText.convert("A normal\nmessage   with text."),
            "A normal message with text."
        )
    }
}
