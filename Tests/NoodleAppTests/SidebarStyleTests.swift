import XCTest
import NoodleCore
@testable import Noodle
@testable import NoodleRuntime

@MainActor final class SidebarStyleTests: XCTestCase {
    private func fixture() throws -> StoreFixture {
        let f = try StoreFixture(); addTeardownBlock { @MainActor in f.cleanUp() }; return f
    }

    func testTheSidebarIsAListUnlessIconsAreChosen() {
        XCTAssertEqual(SidebarStyle.standard, .list)
        XCTAssertEqual(SidebarStyle.key, "sidebarStyle")
        XCTAssertEqual(SidebarStyle.allCases.map(\.name), ["As List", "As Icons"])
    }

    func testNeedsYouTakesPausedConversationsOutOfTheirSections() throws {
        let f = try fixture()
        let group = try f.group()
        let ada = try f.runtime.start(f.a)
        try f.runtime.start(f.b)
        f.store.setPinned(true, conversationID: f.directB.id)

        var sections = f.store.sidebarSections(.standard, separatingNeedsYou: true)
        XCTAssertTrue(sections.needsYou.isEmpty)
        XCTAssertEqual(sections.bots.map(\.id), [f.directA.id])
        XCTAssertEqual(sections.pinned.map(\.id), [f.directB.id])

        ada.transition(.failed, failure: .authenticationRequired)
        sections = f.store.sidebarSections(.standard, separatingNeedsYou: true)
        XCTAssertEqual(Set(sections.needsYou.map(\.id)), [f.directA.id, group.id])
        XCTAssertTrue(sections.bots.isEmpty)
        XCTAssertTrue(sections.groups.isEmpty)
        XCTAssertEqual(sections.pinned.map(\.id), [f.directB.id])

        // The list keeps each conversation in its own section.
        sections = f.store.sidebarSections(.standard)
        XCTAssertTrue(sections.needsYou.isEmpty)
        XCTAssertEqual(sections.bots.map(\.id), [f.directA.id])
        XCTAssertEqual(sections.groups.map(\.id), [group.id])
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
