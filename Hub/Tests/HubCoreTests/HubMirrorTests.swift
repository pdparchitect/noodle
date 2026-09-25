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
                                  access: hub.access, profiles: hub.harnessProfiles, bots: hub.bots, port: 0,
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

    func testTheMirrorSurvivesARelaunchWithoutDoubling() async throws {
        let f = try await fixture()
        let agent = try await f.mirror().createBot(LinkBotDraft(name: "Alfred", provider: "claude-code"))
        let relaunched = f.mirror()
        XCTAssertEqual(relaunched.localAgentIDs, [agent.id])
        await relaunched.sync()
        XCTAssertEqual(try f.local.loadAgents().count, 1)
    }

    func testDeletingABotHereDeletesItOnTheHub() async throws {
        let f = try await fixture()
        let mirror = f.mirror()
        let agent = try await mirror.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code"))
        try await mirror.deleteBot(localAgentID: agent.id)
        XCTAssertTrue(try f.local.loadAgents().isEmpty)
        XCTAssertTrue(try f.hub.repository.loadAgents().isEmpty)
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
}
