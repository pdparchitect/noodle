import XCTest
@testable import HubWire

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

/// Where Foundation cannot parse markdown, previews take the markup off themselves, and show what
/// Foundation's parser would.
final class InlineMarkdownTests: XCTestCase {
    private let inline: [(String, String)] = [
        ("Done — [whetstone](</Users/pdp/Library/Containers/example>) with **three files** and `git`.",
         "Done — whetstone with three files and git."),
        ("Second *item*", "Second item"),
        ("**bold** and __also__ and ***both***", "bold and also and both"),
        ("~~gone~~ now", "gone now"),
        ("snake_case_name and file_name.txt stay", "snake_case_name and file_name.txt stay"),
        ("2 * 3 * 4 is not emphasis", "2 * 3 * 4 is not emphasis"),
        ("an \\*escaped\\* star", "an *escaped* star"),
        ("see <https://example.com/a?b=1>", "see https://example.com/a?b=1"),
        ("``code with ` tick`` here", "code with ` tick here"),
        ("unclosed **bold stays", "unclosed **bold stays"),
        ("*nested **strong** inside*", "nested strong inside"),
        ("[a [nested] link](https://example.com/x_(y)) after", "a [nested] link after"),
        ("`*not emphasis*` in code", "*not emphasis* in code"),
        ("- a list marker stays inline", "- a list marker stays inline"),
        ("Plain text, untouched.", "Plain text, untouched."),
    ]
    private let blocks: [(String, String)] = [
        ("## Result", "Result"),
        ("- First item", "First item"),
        ("12. Twelfth *item*", "Twelfth item"),
        ("> Quoted **words**", "Quoted words"),
        ("---", "⸻"),
    ]

    func testStrippedMarkupLeavesTheVisibleText() {
        for (markdown, text) in inline { XCTAssertEqual(InlineMarkdown.stripped(markdown), text, markdown) }
        for (markdown, text) in blocks { XCTAssertEqual(InlineMarkdown.stripped(markdown, blocks: true), text, markdown) }
    }

    #if canImport(Darwin)
    func testStrippingAgreesWithFoundationsParser() {
        for (markdown, _) in inline { XCTAssertEqual(InlineMarkdown.stripped(markdown), InlineMarkdown.plainText(markdown), markdown) }
        for (markdown, _) in blocks {
            XCTAssertEqual(InlineMarkdown.stripped(markdown, blocks: true), InlineMarkdown.plainText(markdown, blocks: true), markdown)
        }
    }
    #endif

    /// Each piece of a line with how it is styled, for a screen that draws them where Foundation cannot read
    /// markdown.
    func testRunsCarryTheirStyleAndLinks() {
        typealias Run = InlineMarkdown.Run
        XCTAssertEqual(InlineMarkdown.runs("Some **bold**, *it*, ~~gone~~, `code` and [a link](https://x.com/a_(b)) or <https://y.com>"), [
            Run("Some "), Run("bold", strong: true), Run(", "), Run("it", emphasis: true), Run(", "),
            Run("gone", strikethrough: true), Run(", "), Run("code", code: true), Run(" and "),
            Run("a link", link: "https://x.com/a_(b)"), Run(" or "), Run("https://y.com", link: "https://y.com"),
        ])
        XCTAssertEqual(InlineMarkdown.runs("***both*** and *outer **inner***"), [
            Run("both", strong: true, emphasis: true), Run(" and "), Run("outer ", emphasis: true),
            Run("inner", strong: true, emphasis: true),
        ])
        XCTAssertEqual(InlineMarkdown.runs("Plain."), [Run("Plain.")])
        for (markdown, text) in inline {
            XCTAssertEqual(InlineMarkdown.runs(markdown).map(\.text).joined(), text, markdown)
        }
    }

    #if canImport(Darwin)
    func testRunsAgreeWithFoundationsParser() throws {
        let samples = inline.map(\.0) + ["***both*** and *outer **inner***", "[a link](https://x.com) and <https://y.com>"]
        for markdown in samples {
            let parsed = try AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            let expected = parsed.runs.map { run -> InlineMarkdown.Run in
                let intent = run.inlinePresentationIntent ?? []
                return InlineMarkdown.Run(String(parsed[run.range].characters), strong: intent.contains(.stronglyEmphasized),
                                          emphasis: intent.contains(.emphasized), strikethrough: intent.contains(.strikethrough),
                                          code: intent.contains(.code), link: run.link?.absoluteString)
            }
            XCTAssertEqual(InlineMarkdown.runs(markdown), expected, markdown)
        }
    }
    #endif
}
