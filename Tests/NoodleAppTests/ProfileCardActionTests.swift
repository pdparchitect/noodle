import NoodleCore
import SwiftUI
import XCTest
@testable import Noodle

/// A bot's profile offers the same actions, in the same order, in every app that shows one.
@MainActor final class ProfileCardActionTests: XCTestCase {
    func testABotsActionsKeepOneOrder() {
        let all = ProfileCardAction.botActions(noun: "Bot", name: "Avery", reply: {}, message: {}, canMessage: false,
                                               call: {}, close: {}, extra: [.custom("computer", EmptyView())],
                                               edit: {}, usage: {}, suspension: (false, { _ in }))
        XCTAssertEqual(all.map(\.id), ["Reply", "Message", "Call", "computer", "Edit", "Usage", "suspend"])
        if case .button(_, _, _, let disabled, _) = all[1].kind { XCTAssertTrue(disabled, "No conversation to open") }
        else { XCTFail("Message is a button") }

        let fewest = ProfileCardAction.botActions(noun: "Bot", name: "Avery", reply: nil, message: nil, call: nil, close: {},
                                                  edit: nil, usage: nil, suspension: nil)
        XCTAssertTrue(fewest.isEmpty)
    }

    /// Calling shows the call's conversation, or closes the profile when there is none to show.
    func testCallingShowsTheConversationOrCloses() {
        var shown: [String] = []
        for message in [{ shown.append("message") }, nil] as [(() -> Void)?] {
            let actions = ProfileCardAction.botActions(noun: "Bot", name: "Avery", reply: nil, message: message,
                                                       call: { shown.append("call") }, close: { shown.append("close") },
                                                       edit: nil, usage: nil, suspension: nil)
            guard case .button(_, _, _, _, let action) = actions.first(where: { $0.id == "Call" })?.kind else { return XCTFail() }
            action()
        }
        XCTAssertEqual(shown, ["call", "message", "call", "close"])
    }

    /// Archived, or the bot's own status, faded once older than a heartbeat, which may no longer hold.
    func testAStatusIsArchivedOrTheBotsOwn() {
        var agent = AgentRecord(displayName: "Avery")
        XCTAssertNil(ProfileStatusBadge.bot(agent, heartbeat: 60))
        agent.status = "Reviewing logs"
        agent.statusSetAt = Date()
        XCTAssertEqual(ProfileStatusBadge.bot(agent, heartbeat: 60)?.text, "Reviewing logs")
        XCTAssertEqual(ProfileStatusBadge.bot(agent, heartbeat: 60)?.faded, false)
        agent.statusSetAt = Date(timeIntervalSinceNow: -120)
        XCTAssertEqual(ProfileStatusBadge.bot(agent, heartbeat: 60)?.faded, true)
        agent.archivedAt = Date()
        XCTAssertEqual(ProfileStatusBadge.bot(agent, heartbeat: 60)?.text, "Archived")
    }
}
