import XCTest
@testable import NoodleCore

final class MessageLinkTests: XCTestCase {
    func testAddressesInsideCodeAreNotPreviewed() {
        // A name in code that happens to end like a web address, such as .id or .md, is not a link.
        XCTAssertNil(MessageLink.firstPublicWebURL(in: "A code block:\n\n```swift\nprint(session.id)\n```"))
        XCTAssertNil(MessageLink.firstPublicWebURL(in: "See `report.md` and `https://example.com/inside-code`."))
        XCTAssertNil(MessageLink.firstPublicWebURL(in: "```\n2026-11-19 fetched https://example.com/log\n```"))
        // Outside code, links are found as before, even after code that held a name.
        XCTAssertEqual(MessageLink.firstPublicWebURL(in: "`session.id` aside, read https://example.com/advisory first."),
                       URL(string: "https://example.com/advisory"))
        XCTAssertEqual(MessageLink.firstPublicWebURL(in: "```\nlet a = 1\n```\n\nThe advisory: https://example.com/advisory"),
                       URL(string: "https://example.com/advisory"))
    }

    func testFindsMarkdownLink() {
        XCTAssertEqual(
            MessageLink.firstPublicWebURL(in: "Watch [the trailer](https://www.youtube.com/watch?v=abc#comments)."),
            URL(string: "https://www.youtube.com/watch?v=abc")
        )
    }

    func testFindsBareLink() {
        XCTAssertEqual(
            MessageLink.firstPublicWebURL(in: "See https://example.com/story for details."),
            URL(string: "https://example.com/story")
        )
    }

    func testRejectsLocalAndPrivateDestinations() {
        XCTAssertNil(MessageLink.firstPublicWebURL(in: "http://localhost:8080/private"))
        XCTAssertNil(MessageLink.firstPublicWebURL(in: "http://192.168.1.20/private"))
        XCTAssertNil(MessageLink.firstPublicWebURL(in: "file:///Users/person/secret.txt"))
    }

    func testRejectsCredentials() {
        XCTAssertNil(MessageLink.firstPublicWebURL(in: "https://person:secret@example.com/private"))
    }

    func testUsesNextSafeBareLinkAfterUnsafeOne() {
        XCTAssertEqual(
            MessageLink.firstPublicWebURL(in: "Local http://127.0.0.1 then https://example.com/public"),
            URL(string: "https://example.com/public")
        )
    }
}
