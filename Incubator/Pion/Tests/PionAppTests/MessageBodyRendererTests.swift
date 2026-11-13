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
