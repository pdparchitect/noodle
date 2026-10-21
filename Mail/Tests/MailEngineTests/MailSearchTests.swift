@testable import MailEngine
import XCTest

final class MailSearchTests: XCTestCase {
    /// An empty query searches everything.
    func testEmptyQueryMeansAll() {
        XCTAssertEqual(MailSearch.terms(for: MessageQuery()), [.all])
    }

    /// Every filled-in criterion becomes a term; blank text is ignored rather than matching nothing.
    func testCriteriaBecomeTerms() {
        var query = MessageQuery()
        query.unreadOnly = true
        query.from = " ada@example.com "
        query.subject = "   "
        query.text = "faktura"
        let since = Date(timeIntervalSince1970: 1_790_000_000)
        query.since = since
        XCTAssertEqual(MailSearch.terms(for: query), [.unseen, .from("ada@example.com"), .text("faktura"), .since(since)])
    }

    /// A page is the newest messages first, and the next page starts below the last UID seen.
    func testPagingGoesNewestFirstAndBackwards() {
        let uids = Array(1...50)
        XCTAssertEqual(MailSearch.page(uids, beforeUID: nil, limit: 3), [50, 49, 48])
        XCTAssertEqual(MailSearch.page(uids, beforeUID: 48, limit: 3), [47, 46, 45])
        XCTAssertEqual(MailSearch.page(uids, beforeUID: 2, limit: 3), [1])
        XCTAssertEqual(MailSearch.page([], beforeUID: nil, limit: 3), [])
    }

    /// UIDs from the server may come unsorted or repeated; the page is still clean.
    func testPagingSortsAndDeduplicates() {
        XCTAssertEqual(MailSearch.page([7, 3, 9, 3], beforeUID: nil, limit: 10), [9, 7, 3])
    }
}
