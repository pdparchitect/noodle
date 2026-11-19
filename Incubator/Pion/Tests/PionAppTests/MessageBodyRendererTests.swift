import SwiftUI
import XCTest

@MainActor final class MessageBodyRendererTests: XCTestCase {
    func testRepeatedRowRedrawsPrepareUnchangedMarkdownOnlyOnce() {
        var preparations = 0
        let renderer = MessageBodyRenderer { text in
            preparations += 1
            return MessageBodyRenderer.prepare(text)
        }
        let message = "**Investigation**: inspect `network.log` and [the evidence](https://example.com)."
        for _ in 0..<100 { _ = renderer.render(message) }
        XCTAssertEqual(preparations, 1, "Scrolling back over unchanged text must reuse its prepared Markdown")
        _ = renderer.render(message + " Updated.")
        XCTAssertEqual(preparations, 2, "Edited text must be prepared again")
    }

    func testListsAndParagraphsBecomeBlocksOfTheirOwn() {
        let message = "Read-only look, as asked.\n\nEVIDENCE\n- Dashboard **Platform Usage** draws on one metric.\n* Loki has the lines.\n\n1. Check the rule.\n2) Check the caller.\nNothing else changed."
        let blocks = MessageBodyRenderer().render(message).flatMap { segment -> [MessageBodyRenderer.Block] in
            if case .prose(let blocks) = segment { return blocks }
            return []
        }
        func describe(_ block: MessageBodyRenderer.Block) -> String {
            switch block {
            case .text(let text): "text: " + String(text.characters)
            case .code(let code): "code: " + code
            case .list(let items): "list: " + items.map { "\($0.marker) \(String($0.text.characters))" }.joined(separator: " | ")
            case .quote(let text): "quote: " + String(text.characters)
            case .rule: "rule"
            }
        }
        XCTAssertEqual(blocks.map(describe), [
            "text: Read-only look, as asked.",
            "text: EVIDENCE",
            "list: • Dashboard Platform Usage draws on one metric. | • Loki has the lines.",
            "list: 1. Check the rule. | 2. Check the caller.",
            "text: Nothing else changed.",
        ])
        // An item keeps its own formatting.
        if case .list(let items) = blocks[2] {
            XCTAssertTrue(items[0].text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        }
    }

    func testPreparedTextPreservesFormattingCodeAndSafeLinks() throws {
        let segments = MessageBodyRenderer().render("**Finding** with `inline code` and [evidence](https://example.com).\n\n```swift\nlet answer = 42\n```")
        let blocks = segments.flatMap { segment -> [MessageBodyRenderer.Block] in
            if case .prose(let blocks) = segment { return blocks }
            return []
        }
        let prose = try XCTUnwrap(blocks.compactMap { block -> AttributedString? in
            if case .text(let text) = block { return text }; return nil
        }.first)
        XCTAssertTrue(prose.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(prose.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true && $0.font != nil })
        XCTAssertTrue(prose.runs.contains { $0.link == URL(string: "https://example.com") })
        XCTAssertTrue(blocks.contains { if case .code(let code) = $0 { return code == "let answer = 42" }; return false })
    }

    func testPreparedTextRemovesUnsafeLinksAndKeepsTables() {
        let renderer = MessageBodyRenderer()
        for segment in renderer.render("[Unsafe](file:///etc/passwd) and [safe](https://example.com)") {
            if case .prose(let blocks) = segment {
                for block in blocks {
                    if case .text(let text) = block { XCTAssertFalse(text.runs.contains { $0.link?.scheme == "file" }) }
                }
            }
        }
        let table = renderer.render("| Host | State |\n| --- | --- |\n| LT-42 | Ready |")
        XCTAssertTrue(table.contains { if case .table = $0 { return true }; return false })
    }
}
