import Foundation
import HubLink
@testable import NoodleMobile
import Testing

/// A bot that does not answer for now says why in its row and over its conversation, as on the Mac.
@MainActor struct PausedBotTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func bot(_ name: String, pause: LinkBotPause? = nil) -> LinkBot {
        LinkBot(id: UUID(), conversationID: UUID(), draft: LinkBotDraft(name: name, provider: "codex"), createdAt: now,
                phase: pause == nil ? .ready : .offline, pause: pause)
    }

    @Test func aBotSaysWhyItWaitsAndWhenItContinues() {
        let held = bot("Kai", pause: LinkBotPause(summary: "Paused: plan limit", until: now.addingTimeInterval(3600)))
        let summary = HubChats.pauseSummary(for: .bot(held), members: [], pause: \.pause, now: now)
        #expect(summary == held.pause?.shown(now: now))
        #expect(summary?.hasPrefix("Paused: plan limit, resumes") == true)
        #expect(HubChats.pauseSummary(for: .bot(bot("Ada")), members: [], pause: \.pause, now: now) == nil)
        let waiting = bot("Theo", pause: LinkBotPause(summary: "Paused: recovery interrupted", kickable: true))
        #expect(HubChats.pauseSummary(for: .bot(waiting), members: [], pause: \.pause, now: now) == "Paused: recovery interrupted")
    }

    @Test func aGroupNamesTheBotsThatWait() {
        let kai = bot("Kai", pause: LinkBotPause(summary: "Paused: plan limit")), ada = bot("Ada")
        let theo = bot("Theo", pause: LinkBotPause(summary: "Stopped", kickable: true))
        let group = LinkGroup(id: UUID(), draft: LinkGroupDraft(name: "Crew", publicDescription: "", botIDs: [kai.id, ada.id, theo.id]),
                              createdAt: now)
        #expect(HubChats.pauseSummary(for: .group(group), members: [kai, ada, theo], pause: \.pause, now: now) == "Paused: Kai, Theo")
        #expect(HubChats.pauseSummary(for: .group(group), members: [ada], pause: \.pause, now: now) == nil)
    }

    @Test func aGroupIsGrayOnlyWhenNoBotCanAnswer() {
        #expect(GroupAvatar.phase(of: [.ready, .offline]) == .ready)
        #expect(GroupAvatar.phase(of: [.working, .offline]) == .working)
        #expect(GroupAvatar.phase(of: [.offline, .starting]) == .offline)
    }
}
