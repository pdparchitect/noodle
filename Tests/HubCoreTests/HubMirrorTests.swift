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
        @MainActor func mirror() -> HubMirror { HubMirror(pairing: device, repository: local, directory: folder) }
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-mirror-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(root: root.appendingPathComponent("Hub"), messenger: nil)
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
        return Fixture(hub: hub, ada: ada, device: device, local: local, folder: folder)
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
        XCTAssertEqual(try Data(contentsOf: f.local.attachmentFileURL(arrived)), Data("Summary".utf8))
        XCTAssertEqual(arrived.originalFilename, answer.originalFilename)
        XCTAssertEqual(try f.local.loadMessages(conversationID: local.id).last?.attachmentIDs, [answer.id])
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
