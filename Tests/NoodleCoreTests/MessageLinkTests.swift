import XCTest
@testable import NoodleCore

final class MessageLinkTests: XCTestCase {
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
