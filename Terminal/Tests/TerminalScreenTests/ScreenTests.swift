import Foundation
@testable import TerminalScreen
import XCTest

/// How keys are read from what a terminal sends.
final class KeyTests: XCTestCase {
    private func keys(_ chunks: String...) -> [Key] {
        var decoder = KeyDecoder()
        return chunks.flatMap { decoder.decode(Array($0.utf8)) }
    }

    func testTextAndControlKeys() {
        XCTAssertEqual(keys("hi\r"), [.text("hi"), .enter])
        XCTAssertEqual(keys("\t\u{7F}\u{08}"), [.tab, .backspace, .backspace])
        XCTAssertEqual(keys("\u{03}\u{15}\u{17}"), [.control("c"), .control("u"), .control("w")])
        // Control-J is the line feed, which types a new line; Return is the carriage return.
        XCTAssertEqual(keys("\n"), [.control("j")])
    }

    func testArrowsAndEditingKeys() {
        XCTAssertEqual(keys("\u{1B}[A\u{1B}[B\u{1B}[C\u{1B}[D"), [.up, .down, .right, .left])
        XCTAssertEqual(keys("\u{1B}OA\u{1B}OH\u{1B}OF"), [.up, .home, .end])
        XCTAssertEqual(keys("\u{1B}[5~\u{1B}[6~\u{1B}[3~\u{1B}[H\u{1B}[F\u{1B}[1~\u{1B}[4~"),
                       [.pageUp, .pageDown, .delete, .home, .end, .home, .end])
        XCTAssertEqual(keys("\u{1B}[Z"), [.backTab])
        // With a modifier, the key is the same.
        XCTAssertEqual(keys("\u{1B}[1;5A\u{1B}[1;2D"), [.up, .left])
        // A sequence that means nothing here is left out whole.
        XCTAssertEqual(keys("\u{1B}[99xa"), [.text("a")])
    }

    func testASequenceSplitAcrossReadsIsWaitedFor() {
        XCTAssertEqual(keys("\u{1B}[", "A"), [.up])
        XCTAssertEqual(keys("a\u{1B}", "[B"), [.text("a"), .down])
        XCTAssertEqual(keys("\u{1B}[5", "~"), [.pageUp])
        XCTAssertEqual(keys("\u{1B}[<64;1", "0;5M"), [.wheelUp])
    }

    func testEscapeAloneIsTheEscapeKeyOnceNothingFollows() {
        var decoder = KeyDecoder()
        XCTAssertEqual(decoder.decode([0x1B]), [])
        XCTAssertTrue(decoder.isWaiting)
        XCTAssertEqual(decoder.flush(), [.escape])
        XCTAssertFalse(decoder.isWaiting)
        // Escape followed by an ordinary key is both.
        XCTAssertEqual(keys("\u{1B}x"), [.escape, .text("x")])
        XCTAssertEqual(keys("\u{1B}\u{1B}[A"), [.escape, .up])
    }

    func testACharacterSplitAcrossReadsIsWaitedFor() {
        let bytes = Array("é👍".utf8)
        var decoder = KeyDecoder()
        XCTAssertEqual(decoder.decode(Array(bytes[0..<1])), [])
        XCTAssertEqual(decoder.decode(Array(bytes[1..<4])), [.text("é")])
        XCTAssertEqual(decoder.decode(Array(bytes[4...])), [.text("👍")])
    }

    func testPastedTextIsOnePasteWhateverItHolds() {
        XCTAssertEqual(keys("\u{1B}[200~line one\r\nline\u{1B}[A two\u{1B}[201~x"), [.paste("line one\r\nline\u{1B}[A two"), .text("x")])
        // Its end marker may be split between reads.
        XCTAssertEqual(keys("\u{1B}[200~abc\u{1B}[2", "01~"), [.paste("abc")])
        XCTAssertEqual(keys("\u{1B}[200~ab", "cd\u{1B}[201~"), [.paste("abcd")])
    }

    func testOnlyTheMouseWheelIsReported() {
        XCTAssertEqual(keys("\u{1B}[<64;10;5M\u{1B}[<65;10;5M"), [.wheelUp, .wheelDown])
        // With Shift, Option or Control held, still the wheel.
        XCTAssertEqual(keys("\u{1B}[<68;1;1M\u{1B}[<81;1;1M"), [.wheelUp, .wheelDown])
        // Clicks and releases mean nothing here.
        XCTAssertEqual(keys("\u{1B}[<0;10;5M\u{1B}[<0;10;5m"), [])
        // The older report: the button plus 32, then the column and row.
        XCTAssertEqual(keys("\u{1B}[M\u{60}!!\u{1B}[M\u{61}!!"), [.wheelUp, .wheelDown])
    }
}

/// How text is measured, cut and wrapped to the terminal's columns.
final class TextTests: XCTestCase {
    func testWideCharactersTakeTwoColumns() {
        XCTAssertEqual(columns(of: "abc"), 3)
        XCTAssertEqual(columns(of: "日本"), 4)
        XCTAssertEqual(columns(of: "👍"), 2)
        XCTAssertEqual(columns(of: "❤️"), 2)
        XCTAssertEqual(columns(of: "e\u{301}"), 1)
        XCTAssertEqual(columns(of: "\u{1B}"), 0)
    }

    func testControlCharactersFromAHubAreNeverDrawn() {
        XCTAssertEqual(printable("a\u{1B}]52;c;aGk=\u{07}b"), "a]52;c;aGk=b")
        XCTAssertEqual(printable("a\tb"), "a    b")
        XCTAssertEqual(printable("a\nb"), "a b")
        XCTAssertEqual(printable("a\nb", lines: true), "a\nb")
        XCTAssertEqual(fitted("x\u{1B}[2Jy", to: 10), "x[2Jy")
        XCTAssertFalse(MarkdownText.lines("hi \u{1B}[31mred", width: 40).joined().contains("\u{1B}[31m"))
    }

    func testFittingCutsWithAnEllipsis() {
        XCTAssertEqual(fitted("hello", to: 10), "hello")
        XCTAssertEqual(fitted("hello world", to: 8), "hello w…")
        XCTAssertEqual(fitted("日本語", to: 4), "日…")
        XCTAssertEqual(padded("ab", to: 4), "ab  ")
        XCTAssertEqual(fitted("abc", to: 0), "")
    }

    func testWrappingBreaksAtSpacesAndCutsLongWords() {
        XCTAssertEqual(wrapped("the quick brown fox", width: 10), ["the quick", "brown fox"])
        XCTAssertEqual(wrapped("abcdefghij klm", width: 4), ["abcd", "efgh", "ij", "klm"])
        XCTAssertEqual(wrapped("one\n\ntwo", width: 10), ["one", "", "two"])
        XCTAssertEqual(wrapped("  indented", width: 20), ["  indented"])
        XCTAssertEqual(wrapped("日本語のテキスト", width: 6), ["日本語", "のテキ", "スト"])
        for line in wrapped("a much longer sentence that has to wrap over several lines here", width: 12) {
            XCTAssertLessThanOrEqual(columns(of: line), 12)
        }
    }

    private func plain(_ lines: [String]) -> [String] {
        lines.map { $0.replacingOccurrences(of: #"\x1B\[[0-9;]*m"#, with: "", options: .regularExpression) }
    }

    func testMarkdownShowsItsStylesAndWraps() {
        let lines = MarkdownText.lines("Some **bold** and `code`.", width: 40)
        XCTAssertEqual(plain(lines), ["Some bold and code."])
        XCTAssertTrue(lines[0].contains(Style.bold.code + "bold"))
        XCTAssertTrue(lines[0].contains(Style.accent.code + "code"))
        XCTAssertEqual(plain(MarkdownText.lines("# Title\n- one item that wraps\n> quoted\n```\nlet x = 1\n```", width: 12)),
                       ["Title", "• one item", "  that wraps", "│ quoted", "let x = 1"])
        XCTAssertEqual(plain(MarkdownText.lines("1. first", width: 20)), ["1. first"])
    }

    func testLinksShowWhereTheyGo() {
        XCTAssertEqual(plain(MarkdownText.lines("See [the docs](https://example.com/docs).", width: 80)),
                       ["See the docs (https://example.com/docs)."])
        XCTAssertEqual(plain(MarkdownText.lines("<https://example.com>", width: 80)), ["https://example.com"])
        XCTAssertEqual(MarkdownText.links(in: "[a](https://a.example) and https://b.example/x, then [a](https://a.example) and `https://c.example`")
            .map(\.absoluteString), ["https://a.example", "https://b.example/x"])
        XCTAssertEqual(MarkdownText.links(in: "[app](file:///etc/passwd) mailto:x@y.z"), [])
    }

    func testDaysAreNamedFromToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_GB")
        let now = Date(timeIntervalSince1970: 1_764_000_000) // A Monday afternoon, 24 November 2025.
        XCTAssertEqual(dayName(now.addingTimeInterval(-3_600), now: now, calendar: calendar, locale: locale), "Today")
        XCTAssertEqual(dayName(now.addingTimeInterval(-86_400), now: now, calendar: calendar, locale: locale), "Yesterday")
        XCTAssertEqual(dayName(now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar, locale: locale), "Friday")
        XCTAssertTrue(dayName(now.addingTimeInterval(-400 * 86_400), now: now, calendar: calendar, locale: locale).contains("2024"))
    }
}

/// Lists, the message field and commands.
final class LayoutTests: XCTestCase {
    func testAListShowsTenRowsAroundTheChoice() {
        XCTAssertEqual(listWindow(count: 4, selection: 0, height: 10), 0..<4)
        XCTAssertEqual(listWindow(count: 30, selection: 0, height: 10), 0..<10)
        XCTAssertEqual(listWindow(count: 30, selection: 15, height: 10), 10..<20)
        XCTAssertEqual(listWindow(count: 30, selection: 29, height: 10), 20..<30)
        XCTAssertEqual(listWindow(count: 0, selection: 0, height: 10), 0..<0)
    }

    func testNarrowingFindsNamesBeforeDescriptions() {
        let entries = [("Ada", "writes code"), ("Scout", "finds Ada's notes"), ("Coder", "")]
        let found = narrowed(entries, by: "ada", name: { $0.0 }, detail: { $0.1 })
        XCTAssertEqual(found.map(\.0), ["Ada", "Scout"])
        XCTAssertEqual(narrowed(entries, by: "", name: { $0.0 }, detail: { $0.1 }).count, 3)
        XCTAssertEqual(narrowed(entries, by: "co de", name: { $0.0 }, detail: { $0.1 }).map(\.0), ["Coder", "Ada"])
    }

    func testTheFieldBreaksAtNewLinesAndTheEdge() {
        let input = Array("abcdef\ngh")
        let lines = fieldLines(input, width: 4)
        XCTAssertEqual(lines, [0..<4, 4..<6, 7..<9])
        XCTAssertEqual(fieldLine(of: 0, in: lines), 0)
        XCTAssertEqual(fieldLine(of: 5, in: lines), 1)
        XCTAssertEqual(fieldLine(of: 9, in: lines), 2)
        XCTAssertEqual(fieldLines([], width: 4), [0..<0])
    }

    func testCommandsAreReadFromTheLine() {
        XCTAssertEqual(SlashCommand("/switch Ada Lovelace"), SlashCommand(name: "switch", rest: "Ada Lovelace"))
        XCTAssertEqual(SlashCommand("  /HELP  "), SlashCommand(name: "help", rest: ""))
        XCTAssertEqual(SlashCommand("/file   ~/a b.txt "), SlashCommand(name: "file", rest: "~/a b.txt"))
        XCTAssertNil(SlashCommand("hello /there"))
    }

    func testPathsAreReadAsAShellWould() {
        XCTAssertEqual(typedPath("~/Documents/a.txt", home: "/Users/me"), "/Users/me/Documents/a.txt")
        XCTAssertEqual(typedPath("/tmp/My\\ File.pdf", home: "/Users/me"), "/tmp/My File.pdf")
        XCTAssertEqual(typedPath("'/tmp/My File.pdf' ", home: "/Users/me"), "/tmp/My File.pdf")
        XCTAssertNil(typedPath("  ", home: "/Users/me"))
    }
}

extension SlashCommand {
    init(name: String, rest: String) {
        self.init("/x")!
        self.name = name
        self.rest = rest
    }
}
