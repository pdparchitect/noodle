import Foundation
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class BotRequestLineTests: XCTestCase {
    private func line(_ status: BotRequestStatus, answer: String? = nil) -> BotRequestLine {
        BotRequestLine(requestID: UUID(), helperID: UUID(), helperName: "Accounts", text: "Total the invoices",
                       status: status, answer: answer)
    }

    func testEachStatusHasItsOwnWording() {
        let expected: [(BotRequestLine, String, Bool)] = [
            (line(.waiting), "Asking Accounts", false),
            (line(.answered), "Accounts answered", false),
            (line(.answered, answer: "The total is 120"), "Accounts answered", false),
            (line(.cancelled), "Cancelled asking Accounts", false),
            (line(.expired), "Accounts didn’t answer", true),
            (line(.withheld), "Accounts couldn’t help", true),
        ]
        for (line, title, failed) in expected {
            XCTAssertEqual(line.title(helperName: "Accounts"), title, "\(line.status)")
            XCTAssertEqual(line.failed, failed, "\(line.status)")
        }
    }

    /// The line is a record for the person, not a message from the bot, so it neither marks the
    /// chat unread nor wakes the other bots in it.
    func testARequestLineNeitherMarksTheChatUnreadNorWakesTheGroup() throws {
        let f = try StoreFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        let group = try f.group()
        let helper = try f.runtime.agent("Accounts")
        let first = try f.runtime.start(f.a), second = try f.runtime.start(f.b)
        _ = try f.repository.askBot(helper.id, for: f.a.id, in: group.id, text: "Total the invoices")
        f.store.refreshTranscripts()
        XCTAssertTrue(f.store.messages(for: group).contains { $0.request != nil })
        XCTAssertFalse(f.store.unreadConversationIDs.contains(group.id))
        XCTAssertTrue(first.notifications.isEmpty)
        XCTAssertTrue(second.notifications.isEmpty)
    }
}
