import Foundation
import XCTest
import NoodleDocument

final class MarkdownDocumentTests: XCTestCase {
    private let sample = """
    # Pion tools

    Taken from `Adapters` on **2026-11-25**. See [the docs](https://example.com/docs).

    ## Summary

    | How it signs in | Count |
    |---|--:|
    | OAuth | 13 |
    | Key **pair** | 5 |

    - one
    - two
      - nested
    3. third
    4. fourth

    > quoted
    > on two lines

    ---

    ```swift
    let x = 1

    print(x)
    ```

    - [ ] open task
    - [x] done task
    """

    private func text(_ string: AttributedString) -> String { String(string.characters) }

    func testReadsEveryKindOfBlockInOrder() throws {
        let blocks = MarkdownDocument(sample).blocks
        guard blocks.count == 14 else { return XCTFail("\(blocks.count) blocks: \(blocks)") }

        guard case .heading(1, let title) = blocks[0] else { return XCTFail("\(blocks[0])") }
        XCTAssertEqual(text(title), "Pion tools")

        guard case .paragraph(let intro) = blocks[1] else { return XCTFail("\(blocks[1])") }
        XCTAssertEqual(text(intro), "Taken from Adapters on 2026-11-25. See the docs.")
        XCTAssertTrue(intro.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        XCTAssertTrue(intro.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertEqual(intro.runs.compactMap(\.link), [URL(string: "https://example.com/docs")!])

        guard case .heading(2, _) = blocks[2] else { return XCTFail("\(blocks[2])") }

        guard case .table(let table) = blocks[3] else { return XCTFail("\(blocks[3])") }
        XCTAssertEqual(table.header.map(text), ["How it signs in", "Count"])
        XCTAssertEqual(table.rows.map { $0.map(text) }, [["OAuth", "13"], ["Key pair", "5"]])
        XCTAssertEqual(table.alignments, [.leading, .trailing])

        guard case .listItem(let one) = blocks[4], case .listItem(let nested) = blocks[6],
              case .listItem(let third) = blocks[7] else { return XCTFail("\(blocks[4...7])") }
        XCTAssertEqual(one.marker, "•"); XCTAssertEqual(one.depth, 1); XCTAssertEqual(text(one.text), "one")
        XCTAssertEqual(nested.depth, 2); XCTAssertEqual(text(nested.text), "nested")
        XCTAssertEqual(third.marker, "3."); XCTAssertEqual(text(third.text), "third")

        guard case .quote(let quote) = blocks[9] else { return XCTFail("\(blocks[9])") }
        XCTAssertEqual(text(quote), "quoted on two lines")

        guard case .rule = blocks[10] else { return XCTFail("\(blocks[10])") }

        guard case .code(let language, let code) = blocks[11] else { return XCTFail("\(blocks[11])") }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(code, "let x = 1\n\nprint(x)")

        guard case .listItem(let open) = blocks[12], case .listItem(let done) = blocks[13] else { return XCTFail() }
        XCTAssertEqual(open.task, .open); XCTAssertEqual(text(open.text), "open task")
        XCTAssertEqual(done.task, .done); XCTAssertEqual(text(done.text), "done task")
    }

    /// A link the document carries can only open a web page or write an email, never a file or an app.
    func testKeepsOnlyWebAndEmailLinks() {
        let blocks = MarkdownDocument("[web](https://a.b) [mail](mailto:a@b.c) [file](file:///etc/hosts) [app](x-app://do) [path](docs/a.md)").blocks
        guard case .paragraph(let text) = blocks.first else { return XCTFail("\(blocks)") }
        XCTAssertEqual(text.runs.compactMap(\.link?.absoluteString), ["https://a.b", "mailto:a@b.c"])
    }

    func testTellsMarkdownFilesApart() {
        XCTAssertTrue(MarkdownDocument.isMarkdown(name: "notes.md", mediaType: "application/octet-stream"))
        XCTAssertTrue(MarkdownDocument.isMarkdown(name: "README.MARKDOWN", mediaType: ""))
        XCTAssertTrue(MarkdownDocument.isMarkdown(name: "notes", mediaType: "text/markdown"))
        XCTAssertFalse(MarkdownDocument.isMarkdown(name: "notes.txt", mediaType: "text/plain"))
    }
}
