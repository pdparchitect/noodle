import XCTest
@testable import HubLink

final class ConversationRowDetailTests: XCTestCase {
    func testLatestMessageIsTheDefaultOfThreeChoices() {
        XCTAssertEqual(ConversationRowDetail.standard, .latestMessage)
        XCTAssertEqual(ConversationRowDetail.key, "sidebarRowDetail")
        XCTAssertEqual(ConversationRowDetail.allCases.map(\.name), ["Latest Message", "Description", "Status"])
    }

    func testEachChoiceFallsBackToTheLatestMessage() {
        func line(_ detail: ConversationRowDetail, isGroup: Bool = false, description: String? = nil,
                  status: String? = nil, reply: String? = nil) -> String {
            detail.line(isGroup: isGroup, description: description, status: status, latestReply: { reply },
                        latestMessage: "Thanks")
        }
        XCTAssertEqual(line(.latestMessage, description: "Plans", status: "Busy", reply: "Done"), "Thanks")

        XCTAssertEqual(line(.description, description: " Plans the release\n"), "Plans the release")
        XCTAssertEqual(line(.description, description: "  "), "Thanks")

        XCTAssertEqual(line(.status, status: "Drafting notes", reply: "Done"), "Drafting notes")
        XCTAssertEqual(line(.status, reply: "Done"), "Done", "The bot's own reply, not the person's message after it")
        XCTAssertEqual(line(.status, reply: " "), "Thanks")
        XCTAssertEqual(line(.status, isGroup: true, status: "Busy", reply: "Done"), "Thanks",
                       "A group has a status per bot, so it keeps its latest message")
    }
}
