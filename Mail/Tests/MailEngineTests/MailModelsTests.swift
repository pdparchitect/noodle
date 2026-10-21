import MailEngine
import XCTest

final class MailModelsTests: XCTestCase {
    /// A row is one short line of JSON: sorted keys, ISO dates, and no keys for missing values, which keeps bot tokens down.
    func testRowEncodesCompactly() throws {
        let row = MessageRow(uid: 42, date: Date(timeIntervalSince1970: 1_790_755_200), from: "Ada <ada@example.com>",
                             subject: nil, seen: false, attachments: 1)
        XCTAssertEqual(try MailJSON.encode(row),
                       #"{"attachments":1,"date":"2026-09-30T08:00:00Z","from":"Ada <ada@example.com>","seen":false,"uid":42}"#)
    }

    /// Asking for zero, a negative number or thousands of messages still returns a sane page.
    func testLimitStaysBetweenOneAndOneHundred() {
        var query = MessageQuery()
        XCTAssertEqual(query.clampedLimit, 20)
        query.limit = 0
        XCTAssertEqual(query.clampedLimit, 1)
        query.limit = -5
        XCTAssertEqual(query.clampedLimit, 1)
        query.limit = 5000
        XCTAssertEqual(query.clampedLimit, 100)
    }

    /// Folder roles are plain words in JSON, so a bot can pick the Sent folder without knowing its local name.
    func testFolderEncodesItsRole() throws {
        XCTAssertEqual(try MailJSON.encode(MailFolder(name: "Odeslan&AOk-", role: .sent)), #"{"name":"Odeslan&AOk-","role":"sent"}"#)
        XCTAssertEqual(try MailJSON.encode(MailFolder(name: "Faktury", role: nil)), #"{"name":"Faktury"}"#)
    }
}
