import AppKit
import BrowserBridge
import Foundation
import HubCore
import HubLink
import NoodleCore
import NoodleHubClient
import XCTest

/// Noodle's copy of the bots it keeps on a Hub, against a real Hub over QUIC on this Mac.
@MainActor final class HubMirrorTests: XCTestCase {
    private struct Fixture {
        let hub: Hub
        let ada: HubUser
        let device: HubPairing
        let local: WorkspaceRepository
        let folder: URL
        let link: HubLinkService
        @MainActor func mirror() -> HubMirror { HubMirror(pairing: device, repository: local, directory: folder) }
    }

    /// `browser` stands in for Noodle Browser on the Hub's Mac, and `surfaces` for the live views of its tabs.
    private func fixture(browser: HubBrowsersTests.FakeBrowser? = nil, surfaces: FakeSurfaces? = nil) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-mirror-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let hub: Hub
        if let browser {
            let opener: (@Sendable (BrowserRequest) async throws -> SurfaceSocket)? = surfaces.map { surfaces in
                { try surfaces.open("\($0.browserID!) \($0.tabID!)") }
            }
            hub = Hub(root: root.appendingPathComponent("Hub"), messenger: nil, browser: { try browser.call($0) },
                      surfaces: SurfaceOpeners(browser: opener))
        } else { hub = Hub(root: root.appendingPathComponent("Hub"), messenger: nil) }
        try hub.repository.prepare()
        let link = HubLinkService(hubName: "Mac mini", directory: root.appendingPathComponent("Hub/Link"),
                                  access: hub.access, profiles: hub.harnessProfiles, bots: hub.bots,
                                  connections: hub.connections, computers: hub.computers, browsers: hub.browsers, port: 0,
                                  localEndpoints: { [LinkEndpoint(host: "::1", port: $0)] })
        await link.start()
        addTeardownBlock { await MainActor.run { link.stop() } }
        guard case .listening = link.state else { throw XCTSkip("Could not listen: \(link.state)") }
        let family = try hub.access.addPlan(named: "Family")
        hub.access.set(HubHarness(provider: .claudeCode, profile: nil), included: true, in: family)
        let ada = try hub.access.addUser(named: "Ada")
        hub.access.move(ada, to: family)
        let folder = root.appendingPathComponent("Noodle/Hubs/one")
        let device = HubPairing(directory: folder, deviceName: "Mac")
        await device.join(link.invite(ada).url().absoluteString)
        XCTAssertNil(device.error)
        let local = WorkspaceRepository(rootURL: root.appendingPathComponent("Noodle"))
        try local.prepare()
        return Fixture(hub: hub, ada: ada, device: device, local: local, folder: folder, link: link)
    }

    private func conversation(of agent: UUID, in repository: WorkspaceRepository) throws -> BotConversation {
        try XCTUnwrap(repository.loadConversations().first { $0.kind == .direct && $0.participantIDs == [agent] })
    }

    func testCreatingABotKeepsItOnTheHubAndShowsItHere() async throws {
        let f = try await fixture()
        let mirror = f.mirror()
        let agent = try await mirror.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code", backstory: "A butler."))
        XCTAssertEqual(try f.local.loadAgents().map(\.displayName), ["Alfred"])
        XCTAssertEqual(mirror.localAgentIDs, [agent.id])
        XCTAssertEqual(try f.hub.repository.loadAgents().map(\.displayName), ["Alfred"])
        XCTAssertEqual(try f.local.loadAgentBackstory(agent), "A butler.")
    }

    /// A bot's voice is chosen here and kept on the Hub, which calls with it.
    func testABotsVoiceTravelsToTheHubAndBack() async throws {
        let f = try await fixture()
        let plan = try XCTUnwrap(f.hub.access.plans.first { $0.name == "Family" })
        f.hub.access.set(HubHarness(provider: .codex, profile: nil), included: true, in: plan)
        let mirror = f.mirror()
        var draft = LinkBotDraft(name: "Yuki", provider: "codex")
        draft.voice = "maple"
        let agent = try await mirror.createBot(draft)
        let hubAgent = try XCTUnwrap(f.hub.repository.loadAgents().first)
        XCTAssertEqual(try f.hub.repository.loadAgentVoice(hubAgent), "maple")
        XCTAssertEqual(try f.local.loadAgentVoice(agent), "maple")

        draft.voice = "sol"
        try await mirror.updateBot(localAgentID: agent.id, with: draft)
        XCTAssertEqual(try f.hub.repository.loadAgentVoice(hubAgent), "sol")
        XCTAssertEqual(try f.local.loadAgentVoice(agent), "sol")
    }

    /// Whether a bot can be called comes from the Hub, for shared bots too, which arrive without their harness.
    func testTheHubSaysWhichBotsCanBeCalledIncludingSharedOnes() async throws {
        let f = try await fixture()
        let plan = try XCTUnwrap(f.hub.access.plans.first { $0.name == "Family" })
        f.hub.access.set(HubHarness(provider: .codex, profile: nil), included: true, in: plan)
        let mirror = f.mirror()
        let speaking = try await mirror.createBot(LinkBotDraft(name: "Yuki", provider: "codex"))
        let quiet = try await mirror.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code"))
        XCTAssertTrue(mirror.canCall(agent: speaking.id))
        XCTAssertFalse(mirror.canCall(agent: quiet.id))

        let grace = try f.hub.access.addUser(named: "Grace")
        try await mirror.share(localAgentID: speaking.id, with: [grace.id])
        let root = f.folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let graceFolder = root.appendingPathComponent("Grace/Hubs/one")
        let device = HubPairing(directory: graceFolder, deviceName: "Grace")
        await device.join(f.link.invite(grace).url().absoluteString)
        let local = WorkspaceRepository(rootURL: root.appendingPathComponent("Grace"))
        try local.prepare()
        let graces = HubMirror(pairing: device, repository: local, directory: graceFolder)
        await graces.sync()
        let shared = try XCTUnwrap(try local.loadAgents().first)
        XCTAssertTrue(graces.canCall(agent: shared.id))
    }

    /// A call needs the bot running now, unlike a message it picks up later: the Hub in reach, the bot ready or
    /// working, and not paused.
    func testOnlyABotRunningOnAConnectedHubCanBeCalledNow() async throws {
        XCTAssertTrue(HubMirror.canCallNow(canCall: true, isConnected: true, phase: .ready, isPaused: false))
        XCTAssertTrue(HubMirror.canCallNow(canCall: true, isConnected: true, phase: .working, isPaused: false))
        XCTAssertTrue(HubMirror.canCallNow(canCall: true, isConnected: true, phase: nil, isPaused: false),
                      "a Hub that does not say lets the call be tried")
        for phase in [AgentRuntimePhase.offline, .starting, .failed] {
            XCTAssertFalse(HubMirror.canCallNow(canCall: true, isConnected: true, phase: phase, isPaused: false), "\(phase)")
        }
        XCTAssertFalse(HubMirror.canCallNow(canCall: true, isConnected: false, phase: .ready, isPaused: false))
        XCTAssertFalse(HubMirror.canCallNow(canCall: true, isConnected: true, phase: .ready, isPaused: true))
        XCTAssertFalse(HubMirror.canCallNow(canCall: false, isConnected: true, phase: .ready, isPaused: false))

        let f = try await fixture()
        let plan = try XCTUnwrap(f.hub.access.plans.first { $0.name == "Family" })
        f.hub.access.set(HubHarness(provider: .codex, profile: nil), included: true, in: plan)
        let mirror = f.mirror()
        let agent = try await mirror.createBot(LinkBotDraft(name: "Yuki", provider: "codex"))
        XCTAssertTrue(mirror.canCall(agent: agent.id))
        XCTAssertFalse(mirror.canCallNow(agent: agent.id), "callable with the Hub out of reach")
    }

    /// A call the Hub keeps shows here as its card, live at first and with what was said once it ends.
    func testCallCardsFromTheHubShowHereAndGetTheirTranscriptWhenTheCallEnds() async throws {
        let f = try await fixture()
        let mirror = f.mirror()
        let agent = try await mirror.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code"))
        let hubAgent = try XCTUnwrap(f.hub.repository.loadAgents().first)
        let hubConversation = try conversation(of: hubAgent.id, in: f.hub.repository)
        let local = try conversation(of: agent.id, in: f.local)
        let card = try f.hub.repository.recordVoiceCall(agentID: hubAgent.id, conversationID: hubConversation.id)
        await mirror.sync()
        let live = try XCTUnwrap(f.local.loadMessages(conversationID: local.id).first { $0.id == card.id })
        XCTAssertEqual(live.call?.agentID, agent.id, "The card names the bot as it is known here")
        XCTAssertNil(live.call?.endedAt)

        let said = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try f.hub.repository.finishVoiceCall(messageID: card.id, conversationID: hubConversation.id,
                                                 lines: [VoiceCallLine(.person, "Is it done?", at: said), VoiceCallLine(.bot, "Yes.", at: said)],
                                                 endedAt: said)
        await mirror.sync()
        let ended = try XCTUnwrap(f.local.loadMessages(conversationID: local.id).first { $0.id == card.id })
        XCTAssertNotNil(ended.call?.endedAt)
        XCTAssertEqual(ended.call?.lines.map(\.text), ["Is it done?", "Yes."])
        XCTAssertEqual(ended.call?.lines.map(\.speaker), [.person, .bot])
        XCTAssertEqual(try f.local.loadMessages(conversationID: local.id).filter { $0.call != nil }.count, 1)
    }

    /// A call a bot on the Hub places rings here with the bot and conversation as known here, until it is
    /// declined from here; the Hub keeps its card, which shows here as a declined call.
    func testABotsCallOnTheHubRingsHereAndCanBeDeclined() async throws {
        let f = try await fixture()
        let plan = try XCTUnwrap(f.hub.access.plans.first { $0.name == "Family" })
        f.hub.access.set(HubHarness(provider: .codex, profile: nil), included: true, in: plan)
        let mirror = f.mirror()
        let agent = try await mirror.createBot(LinkBotDraft(name: "Yuki", provider: "codex"))
        let hubAgent = try XCTUnwrap(f.hub.repository.loadAgents().first)
        let local = try conversation(of: agent.id, in: f.local)
        var rang: [AgentCallRequest] = [], stopped: [UUID] = []
        mirror.onCallRinging = { rang.append($0) }
        mirror.onCallStopped = { stopped.append($0) }
        let running = Task { await mirror.run() }
        addTeardownBlock { running.cancel() }
        for _ in 0..<50 where !mirror.isConnected { try await Task.sleep(for: .milliseconds(100)) }

        let request = try f.hub.repository.requestCall(agentID: hubAgent.id, reason: "The build is broken")
        f.hub.bots.ringCall(of: hubAgent.id)
        for _ in 0..<50 where rang.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        let ringing = try XCTUnwrap(rang.first)
        XCTAssertEqual(ringing.id, request.id)
        XCTAssertEqual(ringing.agentID, agent.id)
        XCTAssertEqual(ringing.conversationID, local.id)
        XCTAssertEqual(ringing.reason, "The build is broken")
        // Seconds left travel, not a time, so it ends here when it ends on the Hub, give or take the trip.
        XCTAssertEqual(ringing.expiresAt.timeIntervalSince(request.expiresAt), 0, accuracy: 5)

        try await mirror.declineCall(request.id)
        for _ in 0..<50 where stopped.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(stopped, [request.id])
        await mirror.sync()
        let cards = try f.local.loadMessages(conversationID: local.id).compactMap(\.call)
        XCTAssertEqual(cards.map(\.unanswered), [.declined])
        XCTAssertEqual(cards.first?.agentID, agent.id)
        XCTAssertEqual(cards.first?.reason, "The build is broken")
    }

    /// Sharing a bot from this Mac, and a bot someone shared with this Mac's user, which they can
    /// only talk with: it shows whose it is, and the mirror keeps nothing of how it is made.
    func testBotsAreSharedFromHereAndSharedBotsShowWhoseTheyAre() async throws {
        let f = try await fixture()
        let mirror = f.mirror()
        let agent = try await mirror.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code", backstory: "A butler."))
        let grace = try f.hub.access.addUser(named: "Grace")
        let people = try await mirror.people()
        XCTAssertEqual(people, [LinkPerson(id: grace.id, name: "Grace")])
        try await mirror.share(localAgentID: agent.id, with: [grace.id])
        XCTAssertEqual(mirror.sharedWith(agent: agent.id), [grace.id])
        XCTAssertEqual(mirror.sharedNames(agent: agent.id), ["Grace"])
        XCTAssertNil(mirror.owner(ofAgent: agent.id))
        // Known by name after a relaunch too, once the Hub is followed again.
        let relaunched = f.mirror()
        await relaunched.sync()
        XCTAssertEqual(relaunched.sharedNames(agent: agent.id), ["Grace"])

        let root = f.folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let graceFolder = root.appendingPathComponent("Grace/Hubs/one")
        let device = HubPairing(directory: graceFolder, deviceName: "Grace")
        await device.join(f.link.invite(grace).url().absoluteString)
        let local = WorkspaceRepository(rootURL: root.appendingPathComponent("Grace"))
        try local.prepare()
        let graces = HubMirror(pairing: device, repository: local, directory: graceFolder)
        await graces.sync()
        let shared = try XCTUnwrap(try local.loadAgents().first)
        XCTAssertEqual(shared.displayName, "Alfred")
        XCTAssertEqual(graces.owner(ofAgent: shared.id), "Ada")
        XCTAssertEqual(try local.loadAgentBackstory(shared), "")
        XCTAssertNil(graces.harness(ofAgent: shared.id))

        let conversation = try conversation(of: shared.id, in: local)
        let sent = try local.sendUserMessage(conversationID: conversation.id, body: "Hello")
        await graces.pushPending()
        let remote = try XCTUnwrap(f.hub.repository.loadConversations().first { $0.guest?.id == grace.id })
        XCTAssertEqual(try f.hub.repository.loadMessages(conversationID: remote.id).map(\.id), [sent.id])
    }

    /// A chat effect a bot on the Hub sends waits there; this Mac hears of it, or asks after reconnecting, and
    /// takes it when the conversation is in front, so it plays here and on no other device.
    func testChatEffectsOfHubBotsWaitToBeSeenHere() async throws {
        let f = try await fixture()
        let mirror = f.mirror()
        let agent = try await mirror.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code"))
        let hubAgent = try XCTUnwrap(f.hub.repository.loadAgents().first)
        let remote = try conversation(of: hubAgent.id, in: f.hub.repository)
        let local = try conversation(of: agent.id, in: f.local)
        XCTAssertFalse(mirror.hasWaitingEffect(in: local.id))

        // Sent while this Mac was away: it asks once it follows the Hub again.
        let missed = try f.hub.repository.sendEffect(agentID: hubAgent.id, conversationID: remote.id, kind: "fireworks")
        await mirror.sync()
        XCTAssertTrue(mirror.hasWaitingEffect(in: local.id))
        let first = await mirror.takeEffect(in: local.id)
        XCTAssertEqual(first, LinkEffect(id: missed.id, kind: "fireworks"))
        XCTAssertFalse(mirror.hasWaitingEffect(in: local.id))

        // Sent while it follows the Hub: it hears of it.
        let following = Task { await mirror.run() }
        defer { following.cancel() }
        for _ in 0..<100 where !mirror.isConnected { try await Task.sleep(for: .milliseconds(50)) }
        _ = await mirror.takeEffect(in: local.id)
        try await Task.sleep(for: .seconds(2))
        let sent = try f.hub.repository.sendEffect(agentID: hubAgent.id, conversationID: remote.id, kind: "confetti")
        f.hub.bots.checkForChanges()
        for _ in 0..<100 where !mirror.hasWaitingEffect(in: local.id) { try await Task.sleep(for: .milliseconds(50)) }
        let second = await mirror.takeEffect(in: local.id)
        XCTAssertEqual(second, LinkEffect(id: sent.id, kind: "confetti"))
        let again = await mirror.takeEffect(in: local.id)
        XCTAssertNil(again, "Taken once")
    }

    func testMessagesTravelBothWaysWithTheirIDs() async throws {
        let f = try await fixture()
        let mirror = f.mirror()
        let agent = try await mirror.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code"))
        let local = try conversation(of: agent.id, in: f.local)
        let sent = try f.local.sendUserMessage(conversationID: local.id, body: "Hello")
        await mirror.pushPending()

        let remoteBot = try XCTUnwrap(f.hub.repository.loadAgents().first)
        let remote = try conversation(of: remoteBot.id, in: f.hub.repository)
        XCTAssertEqual(try f.hub.repository.loadMessages(conversationID: remote.id).map(\.id), [sent.id])
        // The bot on the Hub fetches the message and answers.
        _ = try f.hub.repository.latestMessages(for: remoteBot.id)
        _ = try f.hub.repository.sendAgentMessage(agentID: remoteBot.id, conversationID: remote.id, body: "Good evening.")

        await mirror.sync()
        let messages = try f.local.loadMessages(conversationID: local.id)
        XCTAssertEqual(messages.map(\.body), ["Hello", "Good evening."])
        XCTAssertEqual(messages.first?.delivery, .delivered)
        XCTAssertEqual(messages.last?.author, .agent(agent.id))
    }

    func testBotsMadeOrRemovedElsewhereFollowTheHub() async throws {
        let f = try await fixture()
        let mirror = f.mirror()
        let elsewhere = try f.hub.bots.create(LinkBotDraft(name: "Jeeves", provider: "claude-code"), for: f.ada)
        await mirror.sync()
        XCTAssertEqual(try f.local.loadAgents().map(\.displayName), ["Jeeves"])

        try f.hub.bots.delete(elsewhere.id, for: f.ada)
        await mirror.sync()
        XCTAssertTrue(try f.local.loadAgents().isEmpty)
        XCTAssertTrue(mirror.localAgentIDs.isEmpty)
    }

    /// A bot on the Hub shows here whether it is working, as its runtime there reports.
    func testABotShowsWhatItIsDoingOnTheHub() async throws {
        let f = try await fixture()
        let mirror = f.mirror()
        let remote = try f.hub.bots.create(LinkBotDraft(name: "Jeeves", provider: "claude-code"), for: f.ada)
        await mirror.sync()
        let local = try XCTUnwrap(mirror.localAgentIDs.first)
        XCTAssertEqual(mirror.phase(ofAgent: local), f.hub.runtime.snapshot(for: remote.id).phase)
        XCTAssertNil(mirror.phase(ofAgent: UUID()), "a bot not on the Hub had a phase")
    }

    /// A bot on the Hub shows here the status it set there.
    func testABotShowsItsStatusFromTheHub() async throws {
        let f = try await fixture()
        let mirror = f.mirror()
        let remote = try f.hub.bots.create(LinkBotDraft(name: "Jeeves", provider: "claude-code"), for: f.ada)
        _ = try f.hub.repository.setAgentStatus("Polishing silver", agentID: remote.id)
        await mirror.sync()
        XCTAssertEqual(try f.local.loadAgents().first?.status, "Polishing silver")
        _ = try f.hub.repository.setAgentStatus(nil, agentID: remote.id)
        await mirror.sync()
        XCTAssertNil(try f.local.loadAgents().first?.status)
    }

    /// A conversation longer than one answer may carry comes over page by page.
    func testALongConversationComesOverWhole() async throws {
        let f = try await fixture()
        let mirror = f.mirror()
        let agent = try await mirror.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code"))
        let remoteBot = try XCTUnwrap(f.hub.repository.loadAgents().first)
        let remote = try conversation(of: remoteBot.id, in: f.hub.repository)
        let long = String(repeating: "The little bookshop at the end of the street opened at nine. ", count: 800)
        for index in 0..<40 { _ = try f.hub.repository.sendAgentMessage(agentID: remoteBot.id, conversationID: remote.id, body: "\(index) \(long)") }
        await mirror.sync()
        XCTAssertNil(mirror.error)
        let local = try conversation(of: agent.id, in: f.local)
        XCTAssertEqual(try f.local.loadMessages(conversationID: local.id).count, 40)
    }

    func testTheMirrorSurvivesARelaunchWithoutDoubling() async throws {
        let f = try await fixture()
        let agent = try await f.mirror().createBot(LinkBotDraft(name: "Alfred", provider: "claude-code"))
        let relaunched = f.mirror()
        XCTAssertEqual(relaunched.localAgentIDs, [agent.id])
        await relaunched.sync()
        XCTAssertEqual(try f.local.loadAgents().count, 1)
    }

    func testAGroupMadeHereIsKeptOnTheHub() async throws {
        let f = try await fixture()
        let mirror = f.mirror()
        let alfred = try await mirror.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code"))
        let jeeves = try await mirror.createBot(LinkBotDraft(name: "Jeeves", provider: "claude-code"))
        let local = try await mirror.createGroup(named: "House", publicDescription: "Runs the house", agentIDs: [alfred.id, jeeves.id])
        XCTAssertEqual(local.kind, .group)
        XCTAssertEqual(Set(local.participantIDs), [alfred.id, jeeves.id])
        XCTAssertTrue(mirror.owns(conversation: local.id))

        let remote = try XCTUnwrap(f.hub.repository.loadConversations().first { $0.kind == .group })
        XCTAssertEqual(remote.displayName, "House")
        XCTAssertEqual(Set(remote.participantIDs), Set(try f.hub.repository.loadAgents().map(\.id)))

        let sent = try f.local.sendUserMessage(conversationID: local.id, body: "Dinner at eight.")
        await mirror.pushPending()
        XCTAssertEqual(try f.hub.repository.loadMessages(conversationID: remote.id).map(\.id), [sent.id])
        let remoteJeeves = try XCTUnwrap(f.hub.repository.loadAgents().first { $0.displayName == "Jeeves" })
        _ = try f.hub.repository.sendAgentMessage(agentID: remoteJeeves.id, conversationID: remote.id, body: "Very good.")
        await mirror.sync()
        XCTAssertNil(mirror.error)
        let messages = try f.local.loadMessages(conversationID: local.id)
        XCTAssertEqual(messages.map(\.body), ["Dinner at eight.", "Very good."])
        XCTAssertEqual(messages.last?.author, .agent(jeeves.id))

        try await mirror.updateGroup(local.id, named: "Staff", publicDescription: "", agentIDs: [alfred.id])
        XCTAssertEqual(try f.hub.repository.loadConversations().first { $0.id == remote.id }?.participantIDs.count, 1)
        XCTAssertEqual(try f.local.loadConversations().first { $0.id == local.id }?.displayName, "Staff")

        try await mirror.deleteGroup(local.id)
        XCTAssertFalse(try f.hub.repository.loadConversations().contains { $0.kind == .group })
        XCTAssertFalse(try f.local.loadConversations().contains { $0.kind == .group })
        XCTAssertEqual(try f.local.loadAgents().count, 2)
    }

    func testGroupsMadeOrChangedElsewhereFollowTheHub() async throws {
        let f = try await fixture()
        let mirror = f.mirror()
        let alfred = try f.hub.bots.create(LinkBotDraft(name: "Alfred", provider: "claude-code"), for: f.ada)
        let group = try f.hub.bots.createGroup(LinkGroupDraft(name: "House", publicDescription: "", botIDs: [alfred.id]), for: f.ada)
        await mirror.sync()
        let local = try XCTUnwrap(f.local.loadConversations().first { $0.kind == .group })
        XCTAssertEqual(local.displayName, "House")
        XCTAssertEqual(local.participantIDs, Array(mirror.localAgentIDs))

        _ = try f.hub.bots.updateGroup(group.id, with: LinkGroupDraft(name: "Staff", publicDescription: "Downstairs",
                                                                      botIDs: [alfred.id]), for: f.ada)
        await mirror.sync()
        let renamed = try XCTUnwrap(f.local.loadConversations().first { $0.id == local.id })
        XCTAssertEqual(renamed.displayName, "Staff")
        XCTAssertEqual(renamed.publicDescription, "Downstairs")

        try f.hub.bots.deleteGroup(group.id, for: f.ada)
        await mirror.sync()
        XCTAssertFalse(try f.local.loadConversations().contains { $0.kind == .group })
    }

    func testBotsAndGroupsArchivedElsewhereAreArchivedHere() async throws {
        let f = try await fixture()
        let mirror = f.mirror()
        let alfred = try f.hub.bots.create(LinkBotDraft(name: "Alfred", provider: "claude-code"), for: f.ada)
        let group = try f.hub.bots.createGroup(LinkGroupDraft(name: "House", publicDescription: "", botIDs: [alfred.id]), for: f.ada)
        try f.hub.bots.setArchived(true, id: alfred.id, for: f.ada)
        try f.hub.bots.setArchived(true, id: group.id, for: f.ada)
        await mirror.sync()
        XCTAssertNotNil(try f.local.loadAgents().first?.archivedAt)
        XCTAssertNotNil(try f.local.loadConversations().first { $0.kind == .group }?.archivedAt)

        try f.hub.bots.setArchived(false, id: alfred.id, for: f.ada)
        try f.hub.bots.setArchived(false, id: group.id, for: f.ada)
        await mirror.sync()
        XCTAssertNil(try f.local.loadAgents().first?.archivedAt)
        XCTAssertNil(try f.local.loadConversations().first { $0.kind == .group }?.archivedAt)
    }

    func testArchivingHereArchivesOnTheHub() async throws {
        let f = try await fixture()
        let mirror = f.mirror()
        let agent = try await mirror.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code"))
        let group = try await mirror.createGroup(named: "House", publicDescription: "", agentIDs: [agent.id])
        try await mirror.setArchived(true, localAgentID: agent.id)
        try await mirror.setArchived(true, conversation: group.id)
        XCTAssertNotNil(try f.hub.repository.loadAgents().first?.archivedAt)
        XCTAssertNotNil(try f.hub.repository.loadConversations().first { $0.kind == .group }?.archivedAt)
        XCTAssertNotNil(try f.local.loadAgents().first?.archivedAt)
        XCTAssertNotNil(try f.local.loadConversations().first { $0.id == group.id }?.archivedAt)

        try await mirror.setArchived(false, localAgentID: agent.id)
        try await mirror.setArchived(false, conversation: group.id)
        XCTAssertNil(try f.hub.repository.loadAgents().first?.archivedAt)
        XCTAssertNil(try f.local.loadConversations().first { $0.id == group.id }?.archivedAt)
    }

    func testDeletingABotHereDeletesItOnTheHub() async throws {
        let f = try await fixture()
        let mirror = f.mirror()
        let agent = try await mirror.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code"))
        try await mirror.deleteBot(localAgentID: agent.id)
        XCTAssertTrue(try f.local.loadAgents().isEmpty)
        XCTAssertTrue(try f.hub.repository.loadAgents().isEmpty)
    }

    /// Reading here reads on the Hub, and reading on another device reaches this Mac, at once or when it next syncs.
    func testReadingIsSharedWithTheHub() async throws {
        let f = try await fixture()
        let mirror = f.mirror()
        let agent = try await mirror.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code"))
        let local = try conversation(of: agent.id, in: f.local)
        let remoteBot = try XCTUnwrap(f.hub.repository.loadAgents().first)
        let remote = try conversation(of: remoteBot.id, in: f.hub.repository)
        _ = try f.hub.repository.sendAgentMessage(agentID: remoteBot.id, conversationID: remote.id, body: "Good evening.")
        // As the Hub keeps it, which is to the second.
        let reply = try XCTUnwrap(f.hub.repository.loadMessages(conversationID: remote.id).last)
        await mirror.sync()

        await mirror.markRead(conversation: local.id)
        guard case .bots(let listed) = try await f.device.request(.bots) else { return XCTFail("no bots") }
        XCTAssertEqual(listed.first?.readUpTo, reply.createdAt)

        var heard: [Date] = []
        mirror.onRead = { conversation, upTo in if conversation == local.id { heard.append(upTo) } }
        let running = Task { await mirror.run() }
        addTeardownBlock { running.cancel() }
        for _ in 0..<50 where !mirror.isConnected || heard.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        // What the Hub kept, heard on connecting.
        XCTAssertEqual(heard.first, reply.createdAt)

        let later = ChatMessage(id: UUID(), conversationID: remote.id, author: .agent(remoteBot.id), body: "Anything else?",
                                createdAt: reply.createdAt.addingTimeInterval(60), delivery: .delivered)
        try f.hub.repository.append(later)
        try f.hub.bots.markRead(LinkReadMark(conversationID: remote.id, messageID: later.id), for: f.ada)
        for _ in 0..<50 where heard.count < 2 { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(heard.last, later.createdAt)
    }

    /// Pins of the Hub's conversations live on the Hub: one made here reaches it, and one made on another
    /// device shows here, kept so they show at once on the next launch.
    func testPinsAreSharedWithTheHub() async throws {
        let f = try await fixture()
        let mirror = f.mirror()
        let alfred = try await mirror.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code"))
        let jeeves = try await mirror.createBot(LinkBotDraft(name: "Jeeves", provider: "claude-code"))
        let alfredHere = try conversation(of: alfred.id, in: f.local), jeevesHere = try conversation(of: jeeves.id, in: f.local)
        let remoteJeeves = try XCTUnwrap(f.hub.repository.loadAgents().first { $0.displayName == "Jeeves" })
        let jeevesThere = try conversation(of: remoteJeeves.id, in: f.hub.repository)
        XCTAssertEqual(mirror.pinnedConversations, [])

        try await mirror.setPinned(true, conversation: alfredHere.id)
        XCTAssertEqual(mirror.pinnedConversations, [alfredHere.id])
        guard case .bots(let listed) = try await f.device.request(.bots) else { return XCTFail("no bots") }
        XCTAssertNotNil(listed.first { $0.draft.name == "Alfred" }?.pinnedAt)

        let running = Task { await mirror.run() }
        addTeardownBlock { running.cancel() }
        for _ in 0..<50 where !mirror.isConnected { try await Task.sleep(for: .milliseconds(100)) }
        try f.hub.bots.setPinned(true, conversation: jeevesThere.id, for: f.ada)
        for _ in 0..<50 where mirror.pinnedConversations.count < 2 { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(mirror.pinnedConversations, [alfredHere.id, jeevesHere.id])
        running.cancel()

        XCTAssertEqual(f.mirror().pinnedConversations, [alfredHere.id, jeevesHere.id])
    }

    func testRepliesArriveWithoutAskingWhileConnected() async throws {
        let f = try await fixture()
        let mirror = f.mirror()
        let agent = try await mirror.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code"))
        let running = Task { await mirror.run() }
        addTeardownBlock { running.cancel() }
        let remoteBot = try XCTUnwrap(f.hub.repository.loadAgents().first)
        let remote = try conversation(of: remoteBot.id, in: f.hub.repository)
        // Wait for the stream to open before the Hub has news.
        for _ in 0..<50 where !mirror.isConnected { try await Task.sleep(for: .milliseconds(100)) }
        _ = try f.hub.repository.sendAgentMessage(agentID: remoteBot.id, conversationID: remote.id, body: "Good evening.")
        f.hub.bots.checkForChanges()
        let local = try conversation(of: agent.id, in: f.local)
        for _ in 0..<50 where try f.local.loadMessages(conversationID: local.id).isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(try f.local.loadMessages(conversationID: local.id).map(\.body), ["Good evening."])
    }

    func testAttachmentsTravelBothWaysWithTheirIDs() async throws {
        let f = try await fixture()
        let mirror = f.mirror()
        let agent = try await mirror.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code"))
        let local = try conversation(of: agent.id, in: f.local)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Resume-\(UUID()).pdf")
        try Data("%PDF-1.4 resume".utf8).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let attached = try f.local.importAttachment(from: file, into: local.id, mediaType: "application/pdf")
        _ = try f.local.sendUserMessage(conversationID: local.id, body: "What is on this file?", attachmentIDs: [attached.id])
        await mirror.pushPending()
        XCTAssertNil(mirror.error)

        let remoteBot = try XCTUnwrap(f.hub.repository.loadAgents().first)
        let remote = try conversation(of: remoteBot.id, in: f.hub.repository)
        let onHub = try XCTUnwrap(f.hub.repository.loadAttachments(conversationID: remote.id).first)
        XCTAssertEqual(onHub.id, attached.id)
        XCTAssertEqual(try Data(contentsOf: f.hub.repository.attachmentFileURL(onHub)), Data("%PDF-1.4 resume".utf8))
        XCTAssertEqual(try f.hub.repository.loadMessages(conversationID: remote.id).first?.attachmentIDs, [attached.id])

        // The bot answers with a file of its own.
        let reply = FileManager.default.temporaryDirectory.appendingPathComponent("Summary-\(UUID()).txt")
        try Data("Summary".utf8).write(to: reply)
        addTeardownBlock { try? FileManager.default.removeItem(at: reply) }
        let answer = try f.hub.repository.importAttachment(from: reply, into: remote.id, mediaType: "text/plain")
        _ = try f.hub.repository.sendAgentMessage(agentID: remoteBot.id, conversationID: remote.id, body: "Here you go.",
                                                   attachmentIDs: [answer.id])
        await mirror.sync()
        let arrived = try XCTUnwrap(f.local.loadAttachments(conversationID: local.id).first { $0.id == answer.id })
        let opened = try await mirror.file(for: arrived)
        XCTAssertEqual(try Data(contentsOf: opened), Data("Summary".utf8))
        XCTAssertEqual(arrived.originalFilename, answer.originalFilename)
        XCTAssertEqual(try f.local.loadMessages(conversationID: local.id).last?.attachmentIDs, [answer.id])
    }

    /// A file from the Hub shows from the Hub's picture of it and comes down only when it is opened.
    func testFilesFromTheHubComeDownOnlyWhenOpened() async throws {
        let f = try await fixture()
        let mirror = f.mirror()
        let agent = try await mirror.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code"))
        let local = try conversation(of: agent.id, in: f.local)
        let remoteBot = try XCTUnwrap(f.hub.repository.loadAgents().first)
        let remote = try conversation(of: remoteBot.id, in: f.hub.repository)
        let photo = try redPicture(width: 2000, height: 1000)
        let sent = try f.hub.repository.importAttachment(data: photo, originalFilename: "Red.png", into: remote.id, mediaType: "image/png")
        _ = try f.hub.repository.sendAgentMessage(agentID: remoteBot.id, conversationID: remote.id, body: "Here.", attachmentIDs: [sent.id])
        await mirror.sync()
        XCTAssertNil(mirror.error)

        let arrived = try XCTUnwrap(f.local.loadAttachments(conversationID: local.id).first { $0.id == sent.id })
        XCTAssertEqual(arrived.originalFilename, "Red.png")
        XCTAssertEqual(arrived.mediaType, "image/png")
        XCTAssertEqual(arrived.byteCount, Int64(photo.count))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.local.attachmentFileURL(arrived).path),
                       "The file came down before it was opened")
        XCTAssertTrue(mirror.isOnHubOnly(arrived))

        let fetched = try await mirror.preview(of: arrived)
        let preview = try XCTUnwrap(fetched)
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(preview as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(image.width, HubMirror.previewPixels)
        XCTAssertEqual(image.height, HubMirror.previewPixels / 2)
        XCTAssertEqual(mirror.keptPreview(of: arrived), preview)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.local.attachmentFileURL(arrived).path))

        let opened = try await mirror.file(for: arrived)
        XCTAssertEqual(try Data(contentsOf: opened), photo)
        XCTAssertFalse(mirror.isOnHubOnly(arrived))
    }

    /// Files downloaded from the Hub past the limit go, the least recently opened first, and come down again
    /// when opened. Files of messages not sent yet stay.
    func testDownloadedFilesPastTheLimitGoLeastRecentlyOpenedFirst() async throws {
        let f = try await fixture()
        let mirror = f.mirror()
        let agent = try await mirror.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code"))
        let local = try conversation(of: agent.id, in: f.local)
        let remoteBot = try XCTUnwrap(f.hub.repository.loadAgents().first)
        let remote = try conversation(of: remoteBot.id, in: f.hub.repository)
        let sent = try ["One", "Two", "Three"].map { name in
            try f.hub.repository.importAttachment(data: Data(repeating: 1, count: 1000), originalFilename: "\(name).bin",
                                                  into: remote.id, mediaType: "application/octet-stream")
        }
        _ = try f.hub.repository.sendAgentMessage(agentID: remoteBot.id, conversationID: remote.id, body: "Files.",
                                                   attachmentIDs: sent.map(\.id))
        await mirror.sync()
        let files = try f.local.loadAttachments(conversationID: local.id)
        let one = try XCTUnwrap(files.first { $0.id == sent[0].id })
        let two = try XCTUnwrap(files.first { $0.id == sent[1].id })
        let three = try XCTUnwrap(files.first { $0.id == sent[2].id })
        for file in [one, two, three] { _ = try await mirror.file(for: file) }
        let unsent = try f.local.importAttachment(data: Data(repeating: 2, count: 1000), originalFilename: "Mine.bin", into: local.id,
                                                  mediaType: "application/octet-stream")
        _ = try f.local.sendUserMessage(conversationID: local.id, body: "Mine", attachmentIDs: [unsent.id])
        let earlier = Date().addingTimeInterval(-60)
        for (index, file) in [one, two, three].enumerated() {
            try FileManager.default.setAttributes([.modificationDate: earlier.addingTimeInterval(Double(index))],
                                                  ofItemAtPath: f.local.attachmentFileURL(file).path)
        }
        // Opened again, the first is now the most recent.
        _ = try await mirror.file(for: one)

        mirror.dropOldFiles(over: 2000)
        XCTAssertTrue(mirror.isOnHubOnly(two))
        XCTAssertFalse(mirror.isOnHubOnly(one))
        XCTAssertFalse(mirror.isOnHubOnly(three))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.local.attachmentFileURL(unsent).path))

        let again = try await mirror.file(for: two)
        XCTAssertEqual(try Data(contentsOf: again), Data(repeating: 1, count: 1000))
    }

    private func redPicture(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// A comment on a file reaches the bot on the Hub with what it refers to, and the bot's own comments arrive here.
    func testCommentsOnFilesTravelBothWays() async throws {
        let f = try await fixture()
        let mirror = f.mirror()
        let agent = try await mirror.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code"))
        let local = try conversation(of: agent.id, in: f.local)
        let resume = try f.local.importAttachment(data: Data("%PDF-1.4 resume".utf8), originalFilename: "Resume.pdf", into: local.id,
                                                  mediaType: "application/pdf")
        let comment = AttachmentAnnotation(source: resume, quote: "Ten years", comment: "Say eleven")
        let note = try f.local.importAttachment(data: Data(comment.textRepresentation.utf8), originalFilename: "Annotation — Resume.txt",
                                                into: local.id, mediaType: "text/plain", annotation: comment)
        _ = try f.local.sendUserMessage(conversationID: local.id, body: "Fix this", attachmentIDs: [resume.id, note.id])
        await mirror.pushPending()
        XCTAssertNil(mirror.error)

        let remoteBot = try XCTUnwrap(f.hub.repository.loadAgents().first)
        let remote = try conversation(of: remoteBot.id, in: f.hub.repository)
        let onHub = try f.hub.repository.loadAttachments(conversationID: remote.id)
        XCTAssertEqual(onHub.first { $0.id == note.id }?.annotation, comment)

        let hubResume = try XCTUnwrap(onHub.first { $0.id == resume.id })
        let answer = AttachmentAnnotation(source: hubResume, quote: "Ten years", comment: "Changed to eleven")
        let reply = try f.hub.repository.importAttachment(data: Data(answer.textRepresentation.utf8), originalFilename: "Annotation — Resume.txt",
                                                          into: remote.id, mediaType: "text/plain", annotation: answer)
        _ = try f.hub.repository.sendAgentMessage(agentID: remoteBot.id, conversationID: remote.id, body: "Done.", attachmentIDs: [reply.id])
        await mirror.sync()
        XCTAssertEqual(try f.local.loadAttachments(conversationID: local.id).first { $0.id == reply.id }?.annotation, answer)
    }

    /// A link a bot on the Hub shares arrives as the same link with its card, so it opens live here.
    func testLinksFromTheHubStayLinks() async throws {
        let f = try await fixture()
        let mirror = f.mirror()
        let agent = try await mirror.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code"))
        let local = try conversation(of: agent.id, in: f.local)
        let remoteBot = try XCTUnwrap(f.hub.repository.loadAgents().first)
        let remote = try conversation(of: remoteBot.id, in: f.hub.repository)
        let tab = UUID()
        let card = try f.hub.repository.importLinkAttachment(BrowserLink.url(browser: UUID(), tab: tab), into: remote.id,
                                                             card: LinkCard(title: "Hacker News", detail: "https://news.ycombinator.com"))
        _ = try f.hub.repository.sendAgentMessage(agentID: remoteBot.id, conversationID: remote.id, body: "Here it is.",
                                                   attachmentIDs: [card.id])
        await mirror.sync()
        let arrived = try XCTUnwrap(f.local.loadAttachments(conversationID: local.id).first { $0.id == card.id })
        guard case .browser(_, let arrivedTab)? = arrived.companion else { return XCTFail("the link did not arrive as a link") }
        XCTAssertEqual(arrivedTab, tab)
        XCTAssertEqual(arrived.card?.title, "Hacker News")
    }

    func testEditsTravelBothWays() async throws {
        let f = try await fixture()
        let mirror = f.mirror()
        let agent = try await mirror.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code", backstory: "A butler."))
        try await mirror.updateBot(localAgentID: agent.id, with: LinkBotDraft(
            name: "Alfred", provider: "claude-code", publicDescription: "Runs the house", backstory: "A careful butler."))
        let remote = try XCTUnwrap(f.hub.repository.loadAgents().first)
        XCTAssertEqual(try f.hub.repository.loadAgentBackstory(remote), "A careful butler.")
        XCTAssertEqual(remote.publicDescription, "Runs the house")

        // Another device renames it.
        let bot = try XCTUnwrap(try f.hub.bots.bots(for: f.ada).first)
        var draft = bot.draft
        draft.name = "Jeeves"
        draft.backstory = "A valet."
        _ = try f.hub.bots.update(bot.id, with: draft, for: f.ada)
        await mirror.sync()
        let local = try XCTUnwrap(f.local.loadAgents().first)
        XCTAssertEqual(local.displayName, "Jeeves")
        XCTAssertEqual(try f.local.loadAgentBackstory(local), "A valet.")
    }

    /// Backgrounds of conversations on the Hub are the Hub's: whatever is here gives way to it, a
    /// file comes over once until it changes, and one chosen here goes to the Hub.
    func testBackgroundsAreKeptOnTheHub() async throws {
        let f = try await fixture()
        let mirror = f.mirror()
        let agent = try await mirror.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code"))
        let local = try conversation(of: agent.id, in: f.local)
        let remote = try conversation(of: XCTUnwrap(f.hub.repository.loadAgents().first).id, in: f.hub.repository)
        try f.local.setBackground(conversationID: local.id, preset: .sunset)
        await mirror.sync()
        XCTAssertNil(mirror.error)
        XCTAssertTrue(try f.local.loadBackground(conversationID: local.id).isDefault)

        let photo = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-background-\(UUID()).png")
        addTeardownBlock { try? FileManager.default.removeItem(at: photo) }
        try PersonalHubTests.picture(at: photo)
        _ = try f.hub.repository.setBackground(conversationID: remote.id, file: try await PreparedBackgroundFile.prepare(photo))
        await mirror.sync()
        let fetched = try f.local.loadBackground(conversationID: local.id)
        XCTAssertEqual(fetched.mediaKind, .image)
        XCTAssertNotNil(try f.local.backgroundImageURL(fetched, conversationID: local.id).flatMap { NSImage(contentsOf: $0) })
        await mirror.sync()
        XCTAssertEqual(try f.local.loadBackground(conversationID: local.id), fetched, "fetched again although unchanged")

        try f.local.setBackground(conversationID: local.id, preset: .forest)
        await mirror.shareBackground(conversation: local.id)
        XCTAssertNil(mirror.error)
        XCTAssertEqual(try f.hub.repository.loadBackground(conversationID: remote.id), ConversationBackground(preset: .forest))

        let movie = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-background-\(UUID()).mov")
        addTeardownBlock { try? FileManager.default.removeItem(at: movie) }
        try await PersonalHubTests.video(at: movie)
        let chosen = try f.local.setBackground(conversationID: local.id, file: try await PreparedBackgroundFile.prepare(movie))
        await mirror.shareBackground(conversation: local.id)
        XCTAssertNil(mirror.error)
        let onHub = try f.hub.repository.loadBackground(conversationID: remote.id)
        XCTAssertEqual(onHub.mediaKind, .video)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(f.hub.repository.backgroundImageURL(onHub, conversationID: remote.id))),
                       try Data(contentsOf: XCTUnwrap(f.local.backgroundImageURL(chosen, conversationID: local.id))))
        await mirror.sync()
        XCTAssertEqual(try f.local.loadBackground(conversationID: local.id), chosen, "fetched what it sent")

        // Another device takes it away.
        try f.hub.repository.setBackground(conversationID: remote.id, preset: nil)
        await mirror.sync()
        XCTAssertTrue(try f.local.loadBackground(conversationID: local.id).isDefault)
    }

    func testABotGetsTheHubConnectionsChosenForItHere() async throws {
        let f = try await fixture()
        let mirror = f.mirror()
        let agent = try await mirror.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code"))
        let notes = try await mirror.saveConnection(LinkConnectionDraft(name: "Notes", endpoint: URL(string: "https://example.com/mcp")!))
        XCTAssertEqual(mirror.connections.map(\.id), [notes.id])
        XCTAssertEqual(mirror.connectionIDs(forAgent: agent.id), [])

        try await mirror.assignConnections([notes.id], toAgent: agent.id)
        XCTAssertEqual(mirror.connectionIDs(forAgent: agent.id), [notes.id])
        let remote = try XCTUnwrap(try f.hub.repository.loadAgents().first)
        XCTAssertEqual(f.hub.connections.assigned(to: remote.id, for: f.ada), [notes.id])
    }

    /// A browser kept on the Hub is renamed, described and deleted from here, and the list here follows.
    func testABrowserOnTheHubIsEditedAndDeletedFromHere() async throws {
        let f = try await fixture(browser: HubBrowsersTests.FakeBrowser())
        let mirror = f.mirror()
        let work = try await mirror.createBrowser(LinkBrowserDraft(name: "Work"))
        let changed = try await mirror.updateBrowser(work.id, with: LinkBrowserDraft(name: "Office", description: "Sign-ins"))
        XCTAssertEqual(changed.description, "Sign-ins")
        XCTAssertEqual(mirror.browsers.map(\.name), ["Office"])
        XCTAssertEqual(f.hub.browsers.browsers(for: f.ada).map(\.name), ["Office"])
        _ = try await mirror.updateBrowser(work.id, with: LinkBrowserDraft(name: "Office", description: ""))
        XCTAssertNil(mirror.browsers.first?.description)
        try await mirror.deleteBrowser(work.id)
        XCTAssertEqual(mirror.browsers, [])
    }

    /// Settings lists the Hub's browsers again when it opens, with the bots here that have each.
    func testTheHubsBrowsersListAgainWithTheBotsHereThatHaveThem() async throws {
        let f = try await fixture(browser: HubBrowsersTests.FakeBrowser())
        let mirror = f.mirror()
        let agent = try await mirror.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code"))
        // Made on another device.
        let made = try await f.hub.browsers.create(BrowserDraft(name: "Work"), for: f.ada)
        XCTAssertEqual(mirror.browsers, [])
        try await mirror.refreshBrowsers()
        XCTAssertEqual(mirror.browsers.map(\.id), [made.id])
        try await mirror.assignBrowsers([made.id], toAgent: agent.id)
        let bot = try XCTUnwrap(mirror.browsers.first?.botIDs.first)
        XCTAssertEqual(mirror.localAgentID(remote: bot), agent.id)
        XCTAssertNil(mirror.localAgentID(remote: UUID()))
    }

    /// Someone watching a Hub bot's browser live from this Mac signs in with its own fields: the Hub finds the
    /// form of the page the card here shows and fills it in the browser they watch, with only what they entered.
    func testAPersonWatchingABrowserFromHereSignsInToIt() async throws {
        let browser = HubBrowsersTests.FakeBrowser()
        browser.features = [SurfaceSocket.feature, BrowserSignInForm.feature]
        let f = try await fixture(browser: browser, surfaces: FakeSurfaces(width: 800))
        let mirror = f.mirror()
        XCTAssertTrue(mirror.signsInToBrowsers)
        let agent = try await mirror.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code"))
        let local = try conversation(of: agent.id, in: f.local)
        let remoteBot = try XCTUnwrap(f.hub.repository.loadAgents().first)
        let remote = try conversation(of: remoteBot.id, in: f.hub.repository)
        let made = try await f.hub.browsers.create(BrowserDraft(name: "Work"), for: f.ada)
        let card = try f.hub.repository.importLinkAttachment(BrowserLink.url(browser: made.id, tab: UUID()), into: remote.id,
                                                             card: LinkCard(title: "Shop", detail: "https://shop.example.test"))
        _ = try f.hub.repository.sendAgentMessage(agentID: remoteBot.id, conversationID: remote.id, body: "Sign in here.",
                                                   attachmentIDs: [card.id])
        await mirror.sync()

        let channel = try await mirror.openSurface(attachment: card.id, in: local.id)
        defer { channel.cancel() }
        for try await frame in channel.frames { if case .packets? = LinkSurface.message(frame) { break } }
        let form = try await mirror.signInForm(attachment: card.id, in: local.id)
        XCTAssertEqual(form.token, HubBrowsersTests.FakeBrowser.signInToken)
        XCTAssertEqual(form.fields.map(\.kind), [.username, .password])
        var entry = LinkSignInEntry()
        entry.username = "ada@example.com"
        entry.password = "correct horse"
        entry.oneTimeCode = "482913"
        try await mirror.fillSignIn(entry, form: form, attachment: card.id, in: local.id)
        XCTAssertEqual(browser.filled.map(\.browser), [made.id])
        XCTAssertEqual(browser.filled.map(\.values), [BrowserSignInValues(token: HubBrowsersTests.FakeBrowser.signInToken,
                                                                          username: "ada@example.com", password: "correct horse")])
    }

    /// A connected mirror, one of its connections, and the pages it asked the browser to open.
    private func signingIn(page: URL) async throws -> (Fixture, HubMirror, LinkConnection, opened: () -> [URL]) {
        let f = try await fixture()
        let mirror = f.mirror()
        let notes = try await mirror.saveConnection(LinkConnectionDraft(name: "Notes", endpoint: URL(string: "https://example.com/mcp")!))
        f.hub.connections.signInFlow = { _, _, browser in
            _ = try await browser(page)
            return nil
        }
        var opened: [URL] = []
        mirror.onSignInPage = { _, url in
            opened.append(url)
            return URL(string: "noodle://mcp/oauth/callback?code=c1&state=s1")!
        }
        let running = Task { await mirror.run() }
        addTeardownBlock { running.cancel() }
        for _ in 0..<50 where !mirror.isConnected { try await Task.sleep(for: .milliseconds(100)) }
        return (f, mirror, notes, { opened })
    }

    func testASignInStartedHereOpensItsPage() async throws {
        let page = URL(string: "https://auth.example.com/authorize?state=s1")!
        let (_, mirror, notes, opened) = try await signingIn(page: page)
        try await mirror.signIn(notes.id, redirect: URL(string: "noodle://mcp/oauth/callback")!)
        for _ in 0..<50 where opened().isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(opened(), [page])
    }

    func testTheHubCannotOpenASignInPageThisMacDidNotAskFor() async throws {
        let (f, mirror, notes, opened) = try await signingIn(page: URL(string: "https://auth.example.com/authorize?state=s1")!)
        // The Hub pushes a page for a sign-in the mirror never started.
        _ = try await f.device.request(.signIn(connectionID: notes.id, redirect: URL(string: "noodle://mcp/oauth/callback")!))
        for _ in 0..<50 where mirror.error == nil { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNotNil(mirror.error)
        XCTAssertEqual(opened(), [])
    }

    func testASignInPageThatIsNotAWebPageStaysClosed() async throws {
        let (_, mirror, notes, opened) = try await signingIn(page: URL(string: "file:///System/Applications/Calculator.app?state=s1")!)
        try await mirror.signIn(notes.id, redirect: URL(string: "noodle://mcp/oauth/callback")!)
        for _ in 0..<50 where mirror.error == nil { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNotNil(mirror.error)
        XCTAssertEqual(opened(), [])
    }
}
