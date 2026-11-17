import NoodleCore
import SwiftUI
import XCTest
@testable import Noodle

/// What a bot's profile says under its name, in every app that shows one.
@MainActor final class ProfileStatusBadgeTests: XCTestCase {
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
