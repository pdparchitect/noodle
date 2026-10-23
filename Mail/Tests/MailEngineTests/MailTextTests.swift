@testable import MailEngine
import XCTest

final class MailTextTests: XCTestCase {
    private let czech = "Příliš žluťoučký kůň"

    /// Text in its declared charset decodes exactly, including ISO-8859-2, common in Czech mail.
    func testDeclaredCharsetsDecode() {
        XCTAssertEqual(MailText.decode(Data(czech.utf8), charset: "utf-8"), czech)
        XCTAssertEqual(MailText.decode(czech.data(using: .isoLatin2)!, charset: "ISO-8859-2"), czech)
        XCTAssertEqual(MailText.decode(czech.data(using: .windowsCP1250)!, charset: "windows-1250"), czech)
    }

    /// Windows-1250 bytes without a declared charset still read as Czech, not as garbage.
    func testWindows1250WithoutCharsetDecodes() {
        XCTAssertEqual(MailText.decode(czech.data(using: .windowsCP1250)!, charset: nil), czech)
    }

    /// A wrong or unknown charset label falls back instead of failing.
    func testWrongCharsetFallsBack() {
        XCTAssertEqual(MailText.decode(Data(czech.utf8), charset: "x-unknown"), czech)
        XCTAssertEqual(MailText.decode(czech.data(using: .windowsCP1250)!, charset: "us-ascii"), czech)
    }

    /// HTML mail becomes readable text: no styles or scripts, line breaks kept, entities decoded.
    func testHTMLBecomesReadableText() {
        let html = """
        <html><head><style>p { color: red }</style></head><body>
        <p>Dobrý den,</p><p>posíláme fakturu&nbsp;č.&nbsp;17 &amp; dodací list.<br>Díky</p>
        <script>alert(1)</script><ul><li>Faktura</li><li>Dodací list</li></ul>
        </body></html>
        """
        XCTAssertEqual(MailText.plainText(fromHTML: html),
                       "Dobrý den,\nposíláme fakturu č. 17 & dodací list.\nDíky\n\n- Faktura\n- Dodací list")
    }

    /// Numeric entities decode, and runs of blank lines shrink to one.
    func testEntitiesAndBlankLines() {
        XCTAssertEqual(MailText.plainText(fromHTML: "<p>A&#253;&#x10D;</p><br><br><br><p>B</p>"), "Aýč\n\nB")
    }

    /// CR and LF in a header value become spaces, so a subject cannot add headers.
    func testSingleLineRemovesLineBreaks() {
        XCTAssertEqual(MailText.singleLine("Hello\r\nBcc: evil@example.com"), "Hello Bcc: evil@example.com")
        XCTAssertEqual(MailText.singleLine("  Faktura \n č. 17  "), "Faktura č. 17")
    }

    /// An opening style or script tag that never closes hides the rest of the mail, as in a browser, instead of leaking its content into the text.
    func testUnclosedStyleOrScriptDropsTheRest() {
        XCTAssertEqual(MailText.plainText(fromHTML: "Hi<style>p{}"), "Hi")
        XCTAssertEqual(MailText.plainText(fromHTML: "Hi<script>alert(1)<p>more</p>"), "Hi")
    }

    /// Style and script blocks are dropped whatever the letter case of their tags.
    func testBlocksAreDroppedInAnyLetterCase() {
        XCTAssertEqual(MailText.plainText(fromHTML: "<STYLE>p{}</STYLE>Hi"), "Hi")
        XCTAssertEqual(MailText.plainText(fromHTML: "<Script>alert(1)</SCRIPT>Hi"), "Hi")
    }

    /// A header element is not a head element, so its text stays.
    func testHeaderIsNotHead() {
        XCTAssertEqual(MailText.plainText(fromHTML: "<header>Title</header>"), "Title")
    }

    /// Every head, style and script block goes, several in a row and one nested inside another.
    func testEveryBlockIsDropped() {
        XCTAssertEqual(MailText.plainText(fromHTML: "A<style>1</style>B<script>2</script>C<style>3</style>D<head>4</head>E"), "ABCDE")
        XCTAssertEqual(MailText.plainText(fromHTML: "A<style>a<script>b</script>c</style>B"), "AB")
    }

    /// About 200 KB of style tags that never close convert to an empty text.
    func testLongRunOfUnclosedStylesConvertsToNothing() {
        XCTAssertEqual(MailText.plainText(fromHTML: String(repeating: "<style>", count: 200_000 / 7)), "")
    }

    /// A lone "<" in the text stays text and does not swallow the words and tags after it.
    func testLoneLessThanSignStaysText() {
        XCTAssertEqual(MailText.plainText(fromHTML: "<p>1 < 2 and <b>bold</b></p>"), "1 < 2 and bold")
    }

    /// Table cells stay apart on their row, and rows stay on their own lines.
    func testTableCellsAreSeparated() {
        let rows = "<table><tr><td>Položka</td><td>Cena</td></tr><tr><td>Kolo</td><td>59 900 Kč</td></tr></table>"
        XCTAssertEqual(MailText.plainText(fromHTML: rows), "Položka Cena\nKolo 59 900 Kč")
        XCTAssertEqual(MailText.plainText(fromHTML: "<table><tr><th>Položka</th><th>Cena</th></tr></table>"), "Položka Cena")
    }

    /// The named entities common in Czech mail decode to their characters.
    func testNamedEntitiesDecode() {
        let expected = [("&ndash;", "–"), ("&mdash;", "—"), ("&hellip;", "…"), ("&bdquo;", "„"), ("&ldquo;", "“"), ("&rdquo;", "”"),
                        ("&lsquo;", "‘"), ("&rsquo;", "’"), ("&laquo;", "«"), ("&raquo;", "»"), ("&euro;", "€"), ("&copy;", "©"),
                        ("&eacute;", "é"), ("&aacute;", "á"), ("&iacute;", "í"), ("&oacute;", "ó"), ("&uacute;", "ú"), ("&yacute;", "ý")]
        for (entity, character) in expected {
            XCTAssertEqual(MailText.plainText(fromHTML: "<p>\(entity)</p>"), character, entity)
        }
    }

    /// UTF-8 bytes with no declared charset read as UTF-8, not as Windows-1250, which would accept them too and turn them into garbage.
    func testUTF8WithoutCharsetDecodes() {
        let text = "Příliš žluťoučký kůl"
        // Windows-1250 must accept these bytes too, otherwise a wrong order would fail by itself and prove nothing.
        XCTAssertNotNil(String(data: Data(text.utf8), encoding: .windowsCP1250))
        XCTAssertEqual(MailText.decode(Data(text.utf8), charset: nil), text)
    }

    /// An escaped entity stays text: "&amp;lt;" reads as "&lt;", never as "<".
    func testEscapedEntitiesAreDecodedOnce() {
        XCTAssertEqual(MailText.plainText(fromHTML: "<p>&amp;lt; &amp;#65; &amp;eacute;</p>"), "&lt; &#65; &eacute;")
    }

    /// A lone CR, which some servers treat as a line end, becomes a space too.
    func testSingleLineRemovesLoneCarriageReturn() {
        XCTAssertEqual(MailText.singleLine("Hello\rBcc: evil@example.com"), "Hello Bcc: evil@example.com")
    }

    /// A list-item tag that never ends stays text and does not swallow the tag after it.
    func testUnfinishedListItemTagDoesNotSwallowTheNextTag() {
        XCTAssertEqual(MailText.plainText(fromHTML: "<li class=x <b>Faktura</b>"), "<li class=x Faktura")
    }

    /// A long run of list-item tags that never end comes back as it went in, minus the trailing space.
    func testLongRunOfUnfinishedListItemsStaysText() {
        XCTAssertEqual(MailText.plainText(fromHTML: String(repeating: "<li ", count: 50_000)), String(repeating: "<li ", count: 49_999) + "<li")
    }

    /// Many numeric entities decode one for one, with the text between them and any entity that is no character left in place.
    func testManyNumericEntitiesDecode() {
        XCTAssertEqual(MailText.plainText(fromHTML: String(repeating: "&#253;", count: 20_000)), String(repeating: "ý", count: 20_000))
        let mixed = String(repeating: "a&#253;&#xD800;", count: 5_000)
        XCTAssertEqual(MailText.plainText(fromHTML: mixed), String(repeating: "aý&#xD800;", count: 5_000))
    }

    /// A head that never closes ends at the body tag, in any letter case, and whichever of the two comes first decides.
    func testUnclosedHeadEndsAtTheBodyTag() {
        XCTAssertEqual(MailText.plainText(fromHTML: "<html><head><title>T</title><body>Hello"), "Hello")
        XCTAssertEqual(MailText.plainText(fromHTML: "<HTML><HEAD><TITLE>T</TITLE><BODY>Hello"), "Hello")
        XCTAssertEqual(MailText.plainText(fromHTML: "<head>A<body>B</head>C"), "BC")
    }

    /// A head with neither a closing tag nor a body tag loses only its own tag.
    func testUnclosedHeadWithoutBodyLosesOnlyItsTag() {
        XCTAssertEqual(MailText.plainText(fromHTML: "<head>Hello"), "Hello")
    }

    /// A head tag that never ends is only text, so nothing after it is lost.
    func testHeadTagThatNeverEndsStaysText() {
        XCTAssertEqual(MailText.plainText(fromHTML: "Hello <head of sales"), "Hello <head of sales")
    }

    /// About 200 KB of head tags that never close convert to an empty text.
    func testLongRunOfUnclosedHeadsConvertsToNothing() {
        XCTAssertEqual(MailText.plainText(fromHTML: String(repeating: "<head>", count: 200_000 / 6)), "")
    }

    /// Empty cells, spacer cells and tabs do not leave runs of spaces inside a line.
    func testRunsOfSpacesInALineCollapse() {
        XCTAssertEqual(MailText.plainText(fromHTML: "<table><tr><td>A</td><td></td><td>B</td></tr></table>"), "A B")
        XCTAssertEqual(MailText.plainText(fromHTML: "<table><tr><td>A</td><td>&nbsp;</td><td></td><td>B</td></tr></table>"), "A B")
        XCTAssertEqual(MailText.plainText(fromHTML: "<p>A &#9;&#9; B</p>"), "A B")
    }

    /// A header value over 300 characters is cut to 299 plus an ellipsis; a value of exactly 300, and nil, stay as they are.
    func testLongHeaderValuesAreCutWithAnEllipsis() {
        let cut = MailText.capped(String(repeating: "a", count: 5_000))
        XCTAssertEqual(cut?.count, 300)
        XCTAssertEqual(cut?.last, "\u{2026}")
        XCTAssertEqual(cut?.dropLast(), Substring(String(repeating: "a", count: 299)))
        let exact = String(repeating: "b", count: 300)
        XCTAssertEqual(MailText.capped(exact), exact)
        XCTAssertNil(MailText.capped(nil))
    }

    /// A header value is cut between characters, so an emoji joined from several or a letter with its accent is never split.
    func testHeaderValuesAreNeverCutInsideACharacter() {
        let parentAndChild = "\u{1F469}\u{200D}\u{1F467}"
        let accented = "e\u{301}"
        for unit in [parentAndChild, accented] {
            let cut = MailText.capped(String(repeating: unit, count: 400))
            XCTAssertEqual(cut?.count, 300)
            XCTAssertTrue(cut?.dropLast().allSatisfy { $0 == Character(unit) } ?? false)
        }
    }

    /// One character carrying 50,000 combining marks is also cut, by its Unicode scalars, so a single huge character cannot flood a bot.
    func testHeaderValueWithOneHugeCharacterIsBoundedByScalars() {
        let zalgo = "e" + String(repeating: "\u{301}", count: 50_000) + " and a normal tail"
        let cut = MailText.capped(zalgo)
        XCTAssertLessThanOrEqual(cut?.unicodeScalars.count ?? Int.max, 1_200)
        XCTAssertEqual(cut?.last, "\u{2026}")
    }

    /// More than 20 recipients keep the first 20 and one last entry saying how many more there were; 20 stay as they are.
    func testLongRecipientListsKeepTheFirstTwentyAndSayHowManyMore() {
        let many = (1...25).map { "person\($0)@example.com" }
        let cut = MailText.capped(many)
        XCTAssertEqual(cut.count, 21)
        XCTAssertEqual(Array(cut.prefix(20)), Array(many.prefix(20)))
        XCTAssertEqual(cut.last, "\u{2026} and 5 more")
        let twenty = Array(many.prefix(20))
        XCTAssertEqual(MailText.capped(twenty), twenty)
    }

    /// A recipient entry is cut like any header value, even in a list short enough to keep whole, because a display name can be huge.
    func testLongRecipientEntriesAreCutToo() {
        let entries = ["ada@example.com", String(repeating: "n", count: 5_000) + " <spam@example.com>"]
        let cut = MailText.capped(entries)
        XCTAssertEqual(cut.count, 2)
        XCTAssertEqual(cut.first, "ada@example.com")
        XCTAssertEqual(cut.last?.count, 300)
        XCTAssertEqual(cut.last?.last, "\u{2026}")
    }
}
