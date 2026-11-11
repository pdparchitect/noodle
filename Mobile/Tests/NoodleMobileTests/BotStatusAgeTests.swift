import Foundation
import HubLink
@testable import NoodleMobile
import Testing

/// A bot's profile shows how long ago it set its status, and dims it when old, the same as a bot on the Mac.
@MainActor struct BotStatusAgeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func bot(status: String?, setAt: Date?, archived: Bool = false) -> LinkBot {
        LinkBot(id: UUID(), conversationID: UUID(), draft: LinkBotDraft(name: "Scout", provider: "codex"), createdAt: now,
                status: status, statusSetAt: setAt, archivedAt: archived ? now : nil)
    }

    @Test func aRecentStatusShowsItsAgeAndAnOldOneIsDimmed() throws {
        let recent = try #require(AgentProfile.statusAge(of: bot(status: "Busy", setAt: now.addingTimeInterval(-60)),
                                                         heartbeatMinutes: 30, at: now))
        #expect(recent.setAt == now.addingTimeInterval(-60))
        #expect(!recent.stale)
        let old = try #require(AgentProfile.statusAge(of: bot(status: "Busy", setAt: now.addingTimeInterval(-3_600)),
                                                      heartbeatMinutes: 30, at: now))
        #expect(old.stale)
        // The Hub's own heartbeat decides what is old.
        let hourly = try #require(AgentProfile.statusAge(of: bot(status: "Busy", setAt: now.addingTimeInterval(-3_000)),
                                                         heartbeatMinutes: 60, at: now))
        #expect(!hourly.stale)
    }

    @Test func aHubThatDoesNotSayItsHeartbeatGetsTheUsualOne() throws {
        let old = try #require(AgentProfile.statusAge(of: bot(status: "Busy", setAt: now.addingTimeInterval(-1_801)),
                                                      heartbeatMinutes: nil, at: now))
        #expect(old.stale)
    }

    @Test func noAgeWithoutAStatusOrFromAHubThatDoesNotSay() {
        #expect(AgentProfile.statusAge(of: bot(status: nil, setAt: nil), heartbeatMinutes: 30, at: now) == nil)
        #expect(AgentProfile.statusAge(of: bot(status: "Busy", setAt: nil), heartbeatMinutes: 30, at: now) == nil)
        // An archived bot shows "Archived" there instead.
        #expect(AgentProfile.statusAge(of: bot(status: "Busy", setAt: now, archived: true), heartbeatMinutes: 30, at: now) == nil)
    }
}
