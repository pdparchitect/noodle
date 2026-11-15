import XCTest
@testable import HubLink

final class ConversationOrderTests: XCTestCase {
    /// Newest first, as the lists come; the odd ones are unread.
    private let items = [1, 2, 3, 4, 5]
    private func isUnread(_ item: Int) -> Bool { item % 2 == 1 }

    func testNewestFirstKeepsTheOrderGivenWithoutAnUnreadSection() {
        XCTAssertEqual(ConversationOrder.newestFirst.arranged(items, isUnread: isUnread), items)
        XCTAssertEqual(ConversationOrder.newestFirst.unread(items, isUnread: isUnread), [])
    }

    func testUnreadFirstMovesUnreadAheadAndKeepsEachPartInOrder() {
        XCTAssertEqual(ConversationOrder.unreadFirst.arranged(items, isUnread: isUnread), [1, 3, 5, 2, 4])
        XCTAssertEqual(ConversationOrder.unreadFirst.unread(items, isUnread: isUnread), [])
    }

    func testUnreadSectionTakesTheUnreadInOrderAndLeavesSectionsAlone() {
        XCTAssertEqual(ConversationOrder.unreadSection.unread(items, isUnread: isUnread), [1, 3, 5])
        XCTAssertEqual(ConversationOrder.unreadSection.arranged([2, 4], isUnread: isUnread), [2, 4])
    }

    func testSectionsPutPinsOnTopInPinOrderAndTheRestNewestFirst() {
        struct Item: Identifiable { let id: Int; let last: Int }
        let items = [Item(id: 1, last: 10), Item(id: 2, last: 30), Item(id: 3, last: 20), Item(id: 4, last: 40)]
        let sections = ConversationOrder.unreadSection.sections(items, pinned: [3, 1, 9],
            lastActivity: { Date(timeIntervalSince1970: TimeInterval($0.last)) }, isUnread: { $0.id == 4 || $0.id == 1 })
        XCTAssertEqual(sections.pinned.map(\.id), [3, 1], "Pins keep their order, unread or not, and unknown ones drop")
        XCTAssertEqual(sections.unread.map(\.id), [4])
        XCTAssertEqual(sections.rest.map(\.id), [2])
        let newest = ConversationOrder.newestFirst.sections(items, pinned: [],
            lastActivity: { Date(timeIntervalSince1970: TimeInterval($0.last)) }, isUnread: { _ in true })
        XCTAssertEqual(newest.rest.map(\.id), [4, 2, 3, 1])
        XCTAssertEqual(newest.unread.map(\.id), [])
    }

    func testUnknownStoredValueFallsBackToNewestFirst() {
        XCTAssertEqual(ConversationOrder(rawValue: "") ?? .standard, .newestFirst)
    }
}
