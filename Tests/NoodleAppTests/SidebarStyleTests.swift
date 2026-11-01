import HubLink
import XCTest
import NoodleCore
@testable import Noodle
@testable import NoodleRuntime

@MainActor final class SidebarStyleTests: XCTestCase {
    private func fixture() throws -> StoreFixture {
        let f = try StoreFixture(); addTeardownBlock { @MainActor in f.cleanUp() }; return f
    }

    func testTheSidebarIsAListUnlessIconsAreChosen() {
        XCTAssertEqual(ConversationListStyle.standard, .list)
        XCTAssertEqual(ConversationListStyle.key, "sidebarStyle")
        XCTAssertEqual(ConversationListStyle.allCases.map(\.name), ["As List", "As Icons"])
    }

    func testIconLabelSaysWhyABotWaitsThenThatItWorksThenTheLine() {
        XCTAssertEqual(SidebarIconLabel(pause: "Paused: sign-in needed", status: .failed, detail: "Hello"),
                       SidebarIconLabel(text: "Paused: sign-in needed", tone: .attention))
        XCTAssertEqual(SidebarIconLabel(pause: "Paused: Ada", status: .working, detail: "Hello"),
                       SidebarIconLabel(text: "Paused: Ada", tone: .attention))
        XCTAssertEqual(SidebarIconLabel(pause: nil, status: .working, detail: "Hello"),
                       SidebarIconLabel(text: "Working", tone: .working))
        for status in [ConversationRuntimeStatus.ready, .idle] {
            XCTAssertEqual(SidebarIconLabel(pause: nil, status: status, detail: "Hello"),
                           SidebarIconLabel(text: "Hello", tone: .detail))
        }
    }
}
