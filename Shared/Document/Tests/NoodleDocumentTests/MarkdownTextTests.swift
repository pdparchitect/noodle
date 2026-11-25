#if os(macOS)
import AppKit
import XCTest
import NoodleDocument

final class MarkdownTextTests: XCTestCase {
    private let markdown = """
    # Title

    Some **bold** and `code`, with [a link](https://example.com).

    - one
    - [x] done

    > quoted

    | Tool | Count |
    |---|--:|
    | Okta | 13 |

    ```
    let x = 1
    ```
    """

    /// The whole document is one string, in reading order, so a selection can run from any block to any other.
    func testTheDocumentIsOneStringInReadingOrder() {
        let text = MarkdownText.attributedString(MarkdownDocument(markdown)).string
        let parts = ["Title", "Some bold and code, with a link.", "one", "☑", "done", "quoted", "Tool", "Count", "Okta", "13", "let x = 1"]
        var position = text.startIndex
        for part in parts {
            guard let found = text.range(of: part, range: position..<text.endIndex) else { return XCTFail("\(part) after \(text[..<position])") }
            position = found.upperBound
        }
        XCTAssertFalse(text.contains("**") || text.contains("```") || text.contains("|"), text)
    }

    func testStylesEachKindOfBlock() throws {
        let text = MarkdownText.attributedString(MarkdownDocument(markdown), size: 14)
        let string = text.string as NSString
        func attributes(of part: String) -> [NSAttributedString.Key: Any] {
            text.attributes(at: string.range(of: part).location, effectiveRange: nil)
        }
        let title = try XCTUnwrap(attributes(of: "Title")[.font] as? NSFont)
        XCTAssertGreaterThan(title.pointSize, 20)
        XCTAssertTrue(title.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue((attributes(of: "bold")[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        XCTAssertTrue((attributes(of: "code")[.font] as? NSFont)?.isFixedPitch == true)
        XCTAssertEqual(attributes(of: "a link")[.link] as? URL, URL(string: "https://example.com"))

        let cell = try XCTUnwrap((attributes(of: "Okta")[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock)
        XCTAssertEqual(cell.table.numberOfColumns, 2)
        XCTAssertEqual(cell.startingRow, 1)
        XCTAssertEqual((attributes(of: "13")[.paragraphStyle] as? NSParagraphStyle)?.alignment, .right)

        XCTAssertNotNil((attributes(of: "let x = 1")[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.first?.backgroundColor)
        XCTAssertTrue((attributes(of: "let x = 1")[.font] as? NSFont)?.isFixedPitch == true)
        XCTAssertEqual((attributes(of: "quoted")[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.count, 1)
    }
}
#endif
