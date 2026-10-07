import Foundation
import HubCore
import HubLink
import NoodleCore
import NoodleHubClient
import XCTest

/// A bot that runs on this Mac, shared through a Hub with people who talk to it there, against a
/// real Hub over QUIC on this Mac.
@MainActor final class HubHostingTests: XCTestCase {
    private struct Fixture {
        let hub: Hub
        let link: HubLinkService
        let mac: HubPairing
        let local: WorkspaceRepository
        let folder: URL
        let alfred: AgentRecord
        let grace: HubUser
        let gracesPhone: HubPairing
        @MainActor func hosting() -> HubHosting { HubHosting(pairing: mac, repository: local, directory: folder) }
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-hosting-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(root: root.appendingPathComponent("Hub"), messenger: nil)
        try hub.repository.prepare()
        let link = HubLinkService(hubName: "Mac mini", directory: root.appendingPathComponent("Hub/Link"),
                                  access: hub.access, profiles: hub.harnessProfiles, bots: hub.bots, port: 0,
                                  localEndpoints: { [LinkEndpoint(host: "::1", port: $0)] })
        await link.start()
        addTeardownBlock { await MainActor.run { link.stop() } }
        guard case .listening = link.state else { throw XCTSkip("Could not listen: \(link.state)") }
        let ada = try hub.access.addUser(named: "Ada")
        let folder = root.appendingPathComponent("Noodle/Hubs/one")
        let mac = HubPairing(directory: folder, deviceName: "Mac")
        await mac.join(link.invite(ada).url().absoluteString)
        XCTAssertNil(mac.error)
        let local = WorkspaceRepository(rootURL: root.appendingPathComponent("Noodle"))
        try local.prepare()
        let alfred = try local.createAgent(named: "Alfred", harnessIdentifier: "codex", publicDescription: "A butler.").agent
        let grace = try hub.access.addUser(named: "Grace")
        let phone = HubPairing(directory: root.appendingPathComponent("Grace"), deviceName: "Grace")
        await phone.join(link.invite(grace).url().absoluteString)
        XCTAssertNil(phone.error)
        return Fixture(hub: hub, link: link, mac: mac, local: local, folder: folder, alfred: alfred, grace: grace, gracesPhone: phone)
    }

    private func bots(of device: HubPairing) async throws -> [LinkBot] {
        guard case .bots(let bots) = try await device.request(.bots) else { throw XCTSkip("unexpected answer") }
        return bots
    }

    private func messages(in conversation: UUID, of device: HubPairing) async throws -> [LinkMessage] {
        guard case .messages(let page) = try await device.request(.messagePage(LinkMessagePage(conversationID: conversation, after: 0))) else {
            throw XCTSkip("unexpected answer")
        }
        return page.messages
    }

    private func send(_ body: String, to conversation: UUID, from device: HubPairing, attachments: [UUID] = []) async throws -> UUID {
        let id = UUID()
        _ = try await device.request(.send(LinkOutgoingMessage(conversationID: conversation, id: id, body: body, attachmentIDs: attachments)))
        return id
    }

    /// Grace's conversation with the bot, as this Mac keeps it.
    private func guestConversation(_ f: Fixture) throws -> BotConversation {
        try XCTUnwrap(f.local.loadConversations().first { $0.guest != nil && $0.participantIDs == [f.alfred.id] })
    }

    /// Grace talks with the bot on this Mac through the Hub: it hears her by name, its reply reaches her, and
    /// her message shows taken once the bot has read it.
    func testPeopleTalkWithABotOnThisMacThroughTheHub() async throws {
        let f = try await fixture()
        let hosting = f.hosting()
        var woken: [[UUID]] = []
        hosting.onMessages = { woken.append($0) }
        try await hosting.share(f.alfred, with: [f.grace.id])
        await hosting.sync()
        XCTAssertNil(hosting.error)
        XCTAssertEqual(hosting.sharedWith(agent: f.alfred.id), [f.grace.id])
        XCTAssertEqual(hosting.hostedAgentIDs, [f.alfred.id])

        guard let graces = try await bots(of: f.gracesPhone).first else { return XCTFail("not shared") }
        XCTAssertEqual(graces.id, f.alfred.id)
        XCTAssertEqual(graces.draft.name, "Alfred")
        XCTAssertEqual(graces.draft.publicDescription, "A butler.")
        let local = try guestConversation(f)
        XCTAssertEqual(local.id, graces.conversationID)
        XCTAssertEqual(local.guest?.name, "Grace")

        _ = try await send("Hello", to: graces.conversationID, from: f.gracesPhone)
        await hosting.sync()
        XCTAssertEqual(try f.local.loadMessages(conversationID: local.id).map(\.body), ["Hello"])
        XCTAssertEqual(woken, [[f.alfred.id]])
        let read = try f.local.latestMessages(for: f.alfred.id)
        XCTAssertEqual(read.map { "\($0.message.body): \($0.sender.handle.rawValue) \($0.sender.displayName)" }, ["Hello: guest Grace"])

        _ = try f.local.sendAgentMessage(agentID: f.alfred.id, conversationID: local.id, body: "Good evening, Grace.")
        await hosting.step()
        await hosting.sync()
        let seen = try await messages(in: graces.conversationID, of: f.gracesPhone)
        XCTAssertEqual(seen.map(\.body), ["Hello", "Good evening, Grace."], "Each message is on the Hub once")
        XCTAssertEqual(seen.first?.delivered, true)
        XCTAssertEqual(seen.last?.author, .bot(f.alfred.id))
        XCTAssertEqual(try f.local.loadMessages(conversationID: local.id).count, 2, "Nothing comes back doubled")
        XCTAssertEqual(woken.count, 1)
    }

    /// Messages that arrive while this Mac is away, or after Noodle quit, are picked up once, and
    /// what the bot already said is not sent again.
    func testWhatArrivedMeanwhileIsPickedUpOnce() async throws {
        let f = try await fixture()
        let first = f.hosting()
        try await first.share(f.alfred, with: [f.grace.id])
        await first.sync()
        guard let graces = try await bots(of: f.gracesPhone).first else { return XCTFail("not shared") }
        _ = try await send("Hello", to: graces.conversationID, from: f.gracesPhone)
        await first.sync()
        let local = try guestConversation(f)
        _ = try f.local.latestMessages(for: f.alfred.id)
        _ = try f.local.sendAgentMessage(agentID: f.alfred.id, conversationID: local.id, body: "Hello, Grace.")
        await first.step()

        _ = try await send("Are you there?", to: graces.conversationID, from: f.gracesPhone)
        _ = try await send("Tea, please.", to: graces.conversationID, from: f.gracesPhone)
        let relaunched = f.hosting()
        await relaunched.sync()
        await relaunched.sync()
        XCTAssertNil(relaunched.error)
        XCTAssertEqual(try f.local.loadMessages(conversationID: local.id).map(\.body),
                       ["Hello", "Hello, Grace.", "Are you there?", "Tea, please."])
        let seen = try await messages(in: graces.conversationID, of: f.gracesPhone)
        XCTAssertEqual(seen.map(\.body), ["Hello", "Hello, Grace.", "Are you there?", "Tea, please."])
    }

    /// Files travel both ways; links to web pages go along, and those that open live on this Mac stay here.
    func testFilesAndLinksTravelBothWays() async throws {
        let f = try await fixture()
        let hosting = f.hosting()
        try await hosting.share(f.alfred, with: [f.grace.id])
        await hosting.sync()
        guard let graces = try await bots(of: f.gracesPhone).first else { return XCTFail("not shared") }
        let note = LinkAttachment(id: UUID(), filename: "Note.txt", mediaType: "text/plain", byteCount: 3)
        _ = try await f.gracesPhone.request(.upload(conversationID: graces.conversationID, attachment: note, offset: 0, data: Data("cat".utf8)))
        _ = try await send("Look", to: graces.conversationID, from: f.gracesPhone, attachments: [note.id])
        await hosting.sync()
        let local = try guestConversation(f)
        let received = try XCTUnwrap(f.local.loadAttachments(conversationID: local.id).first { $0.id == note.id })
        XCTAssertEqual(try Data(contentsOf: f.local.attachmentFileURL(received)), Data("cat".utf8))
        XCTAssertEqual(try f.local.loadMessages(conversationID: local.id).first?.attachmentIDs, [note.id])

        let drawing = try f.local.importAttachment(data: Data("dog".utf8), originalFilename: "Dog.txt", into: local.id, mediaType: "text/plain")
        let page = try f.local.importLinkAttachment(URL(string: "https://example.com/tea")!, into: local.id)
        let live = try f.local.importLinkAttachment(CompanionLink.computer(UUID(), terminal: nil, view: nil).url, into: local.id,
                                                    card: LinkCard(title: "Build box"))
        _ = try f.local.sendAgentMessage(agentID: f.alfred.id, conversationID: local.id, body: "Here",
                                         attachmentIDs: [drawing.id, page.id, live.id])
        await hosting.step()
        XCTAssertNil(hosting.error)
        let reply = try await messages(in: graces.conversationID, of: f.gracesPhone).last
        // What opens live stays here, and the reply says so.
        XCTAssertEqual(reply?.body, "Here\n\nBuild box opens only on Ada's Mac.")
        XCTAssertEqual(reply?.attachments.map(\.id), [drawing.id, page.id])
        XCTAssertEqual(reply?.attachments.last?.url, URL(string: "https://example.com/tea"))
        guard case .chunk(let data, _) = try await f.gracesPhone.request(.download(conversationID: graces.conversationID,
                                                                                   attachmentID: drawing.id, offset: 0)) else {
            return XCTFail("not downloaded")
        }
        XCTAssertEqual(data, Data("dog".utf8))
    }

    /// Grace sees what the bot is doing while this Mac is connected.
    func testPeopleSeeWhatTheBotIsDoing() async throws {
        let f = try await fixture()
        let hosting = f.hosting()
        var phase = AgentRuntimePhase.ready
        hosting.phase = { _ in phase }
        try await hosting.share(f.alfred, with: [f.grace.id])
        let following = try await f.mac.subscribe()
        let task = Task { for try await _ in following {} }
        defer { task.cancel() }
        await hosting.sync()
        var graces = try await bots(of: f.gracesPhone)
        XCTAssertEqual(graces.first?.phase, .ready)
        phase = .working
        await hosting.step()
        graces = try await bots(of: f.gracesPhone)
        XCTAssertEqual(graces.first?.phase, .working)
    }

    /// Who it is shared with, its name and whether it is archived follow this Mac; nobody keeps
    /// it once it is shared with nobody, or deleted here.
    func testTheBotOnTheHubFollowsThisMac() async throws {
        let f = try await fixture()
        let hosting = f.hosting()
        let bea = try f.hub.access.addUser(named: "Bea")
        try await hosting.share(f.alfred, with: [f.grace.id, bea.id])
        await hosting.sync()
        XCTAssertEqual(Set(try f.local.loadConversations().compactMap(\.guest?.id)), [f.grace.id, bea.id])
        try await hosting.share(f.alfred, with: [bea.id])
        await hosting.sync()
        XCTAssertEqual(try f.local.loadConversations().compactMap(\.guest?.id), [bea.id])
        XCTAssertEqual(hosting.sharedWith(agent: f.alfred.id), [bea.id])
        try await hosting.share(f.alfred, with: [f.grace.id])
        await hosting.sync()

        XCTAssertEqual(hosting.sharedNames(agent: f.alfred.id), ["Grace"])

        // Grace's new name reaches the bot, and the names offered here.
        try f.hub.access.rename(f.grace, to: "Grace Hopper")
        await hosting.sync()
        XCTAssertEqual(try guestConversation(f).guest?.name, "Grace Hopper")
        XCTAssertEqual(hosting.sharedNames(agent: f.alfred.id), ["Grace Hopper"])

        _ = try f.local.updateAgent(f.alfred, displayName: "Jeeves", harnessIdentifier: "codex", modelIdentifier: nil,
                                    reasoningEffort: nil, publicDescription: "A valet.", avatarSymbolName: nil,
                                    avatarColorIndex: nil, avatarImageData: nil)
        await hosting.step()
        var graces = try await bots(of: f.gracesPhone)
        XCTAssertEqual(graces.first?.draft.name, "Jeeves")
        XCTAssertEqual(graces.first?.draft.publicDescription, "A valet.")

        _ = try f.local.setAgentArchived(true, agentID: f.alfred.id)
        await hosting.step()
        graces = try await bots(of: f.gracesPhone)
        XCTAssertEqual(graces, [])
        _ = try f.local.setAgentArchived(false, agentID: f.alfred.id)
        await hosting.step()
        graces = try await bots(of: f.gracesPhone)
        XCTAssertEqual(graces.count, 1)

        try await hosting.share(f.alfred, with: [])
        graces = try await bots(of: f.gracesPhone)
        XCTAssertEqual(graces, [])
        XCTAssertTrue(try f.local.loadConversations().allSatisfy { $0.guest == nil })
        XCTAssertEqual(hosting.hostedAgentIDs, [])

        try await hosting.share(f.alfred, with: [f.grace.id])
        await hosting.sync()
        let agent = try XCTUnwrap(f.local.loadAgents().first)
        try f.local.deleteAgent(agent)
        await hosting.step()
        graces = try await bots(of: f.gracesPhone)
        XCTAssertEqual(graces, [])
        XCTAssertFalse(try f.hub.repository.loadAgents().contains { $0.id == f.alfred.id })
        XCTAssertEqual(hosting.hostedAgentIDs, [])
    }

    /// A reply the bot wrote as it was archived waits, without failing, until the bot is back.
    func testRepliesOfAnArchivedBotWaitUntilItIsBack() async throws {
        let f = try await fixture()
        let hosting = f.hosting()
        try await hosting.share(f.alfred, with: [f.grace.id])
        await hosting.sync()
        guard let graces = try await bots(of: f.gracesPhone).first else { return XCTFail("not shared") }
        _ = try f.local.sendAgentMessage(agentID: f.alfred.id, conversationID: graces.conversationID, body: "One moment.")
        _ = try f.local.setAgentArchived(true, agentID: f.alfred.id)
        await hosting.step()
        XCTAssertNil(hosting.error)
        _ = try f.local.setAgentArchived(false, agentID: f.alfred.id)
        await hosting.step()
        XCTAssertNil(hosting.error)
        let seen = try await messages(in: graces.conversationID, of: f.gracesPhone)
        XCTAssertEqual(seen.map(\.body), ["One moment."])
    }

    /// While Noodle follows the Hub, Grace's message reaches the bot, the bot shows online, and its reply goes back, by themselves.
    func testWhileFollowingTheHubMessagesAndRepliesFlowByThemselves() async throws {
        let f = try await fixture()
        let mirror = HubMirror(pairing: f.mac, repository: f.local, directory: f.folder)
        mirror.hosting.phase = { _ in .ready }
        var woken: [UUID] = []
        mirror.hosting.onMessages = { woken += $0 }
        try await mirror.hosting.share(f.alfred, with: [f.grace.id])
        let following = Task { await mirror.run() }
        defer { following.cancel() }
        func until(_ what: String, _ done: () async throws -> Bool) async throws {
            for _ in 0..<100 { if try await done() { return }; try await Task.sleep(for: .milliseconds(100)) }
            XCTFail("Never \(what)")
        }
        guard let graces = try await bots(of: f.gracesPhone).first else { return XCTFail("not shared") }
        try await until("online") { try await self.bots(of: f.gracesPhone).first?.phase == .ready }

        _ = try await send("Hello", to: graces.conversationID, from: f.gracesPhone)
        try await until("woke the bot") { woken == [f.alfred.id] }
        _ = try f.local.latestMessages(for: f.alfred.id)
        _ = try f.local.sendAgentMessage(agentID: f.alfred.id, conversationID: graces.conversationID, body: "Hello, Grace.")
        try await until("replied") {
            try await self.messages(in: graces.conversationID, of: f.gracesPhone).map(\.body) == ["Hello", "Hello, Grace."]
        }
        try await until("showed it taken") { try await self.messages(in: graces.conversationID, of: f.gracesPhone).first?.delivered == true }

        following.cancel()
        try await until("offline") { try await self.bots(of: f.gracesPhone).first?.phase == .offline }
    }

    /// A second Hub, Studio, that this Mac joined too, with Bea on it.
    private struct SecondHub {
        let hub: Hub
        let link: HubLinkService
        let mac: HubPairing
        let folder: URL
        let bea: HubUser
        let beasPhone: HubPairing
    }

    private func secondHub(_ f: Fixture) async throws -> SecondHub {
        let root = f.folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let other = Hub(root: root.appendingPathComponent("Other"), messenger: nil)
        try other.repository.prepare()
        let link = HubLinkService(hubName: "Studio", directory: root.appendingPathComponent("Other/Link"),
                                  access: other.access, profiles: other.harnessProfiles, bots: other.bots, port: 0,
                                  localEndpoints: { [LinkEndpoint(host: "::1", port: $0)] })
        await link.start()
        addTeardownBlock { await MainActor.run { link.stop() } }
        guard case .listening = link.state else { throw XCTSkip("Could not listen: \(link.state)") }
        let folder = root.appendingPathComponent("Noodle/Hubs/two")
        let mac = HubPairing(directory: folder, deviceName: "Mac")
        await mac.join(link.invite(try other.access.addUser(named: "Ada")).url().absoluteString)
        let bea = try other.access.addUser(named: "Bea")
        let beasPhone = HubPairing(directory: root.appendingPathComponent("Bea"), deviceName: "Bea")
        await beasPhone.join(link.invite(bea).url().absoluteString)
        XCTAssertNil(beasPhone.error)
        return SecondHub(hub: other, link: link, mac: mac, folder: folder, bea: bea, beasPhone: beasPhone)
    }

    /// One bot is shared through every Hub this Mac joined, with people on each, who each reach it
    /// through their own Hub; stopping on one leaves the others.
    func testOneBotIsSharedThroughSeveralHubs() async throws {
        let f = try await fixture()
        let studio = try await secondHub(f)
        let bea = studio.bea, beasPhone = studio.beasPhone
        let one = f.hosting(), two = HubHosting(pairing: studio.mac, repository: f.local, directory: studio.folder)
        try await one.share(f.alfred, with: [f.grace.id])
        try await two.share(f.alfred, with: [bea.id])
        await one.sync()
        await two.sync()
        guard let graces = try await bots(of: f.gracesPhone).first, let beas = try await bots(of: beasPhone).first else {
            return XCTFail("not shared")
        }
        _ = try await send("From Grace", to: graces.conversationID, from: f.gracesPhone)
        _ = try await send("From Bea", to: beas.conversationID, from: beasPhone)
        await one.sync()
        await two.sync()
        let read = try f.local.latestMessages(for: f.alfred.id)
        XCTAssertEqual(Set(read.map { "\($0.message.body): \($0.sender.displayName)" }), ["From Grace: Grace", "From Bea: Bea"])

        _ = try f.local.sendAgentMessage(agentID: f.alfred.id, conversationID: graces.conversationID, body: "Hello, Grace.")
        _ = try f.local.sendAgentMessage(agentID: f.alfred.id, conversationID: beas.conversationID, body: "Hello, Bea.")
        await one.step()
        await two.step()
        let toGrace = try await messages(in: graces.conversationID, of: f.gracesPhone)
        let toBea = try await messages(in: beas.conversationID, of: beasPhone)
        XCTAssertEqual(toGrace.map(\.body), ["From Grace", "Hello, Grace."])
        XCTAssertEqual(toBea.map(\.body), ["From Bea", "Hello, Bea."])

        try await one.share(f.alfred, with: [])
        await two.step()
        let gracesAfter = try await bots(of: f.gracesPhone)
        let beasAfter = try await bots(of: beasPhone)
        XCTAssertEqual(gracesAfter, [])
        XCTAssertEqual(beasAfter.map(\.id), [f.alfred.id])
        XCTAssertEqual(try f.local.loadConversations().compactMap(\.guest?.name), ["Bea"])
        XCTAssertNil(two.error)
    }

    /// What the owner's phone is shown of a bot's sharing on a Hub the Mac joined: the Hub, everyone on it, and whom it is shared with.
    func testAHubDescribesABotsSharingForTheOwnersPhone() async throws {
        let f = try await fixture()
        let mirror = HubMirror(pairing: f.mac, repository: f.local, directory: f.folder)
        let before = try await mirror.sharing(of: f.alfred.id)
        XCTAssertEqual(before.name, "Mac mini")
        XCTAssertEqual(before.id, f.mac.hub?.key.x963.base64EncodedString())
        XCTAssertEqual(before.people.map(\.name), ["Grace"])
        XCTAssertEqual(before.sharedWith, [])
        try await mirror.hosting.share(f.alfred, with: [f.grace.id])
        let after = try await mirror.sharing(of: f.alfred.id)
        XCTAssertEqual(after.sharedWith, [f.grace.id])
    }

    /// What the owner's phone asks the Mac reaches every Hub the Mac joined, each by its own ID: listed
    /// together, and a change goes to that Hub alone.
    func testThePhonesSharingReachesTheRightHub() async throws {
        let f = try await fixture()
        let studio = try await secondHub(f)
        let hubs = [HubMirror(pairing: f.mac, repository: f.local, directory: f.folder),
                    HubMirror(pairing: studio.mac, repository: f.local, directory: studio.folder)]
        let listed = await hubs.sharing(of: f.alfred.id)
        XCTAssertEqual(listed.map(\.name), ["Mac mini", "Studio"], "In the order the Mac lists its Hubs")
        XCTAssertEqual(listed.map { $0.people.map(\.name) }, [["Grace"], ["Bea"]])
        XCTAssertEqual(listed.map(\.id), hubs.map(\.sharingID))

        try await hubs.share(f.alfred, onHub: hubs[1].sharingID, with: [studio.bea.id])
        let beas = try await bots(of: studio.beasPhone)
        let graces = try await bots(of: f.gracesPhone)
        XCTAssertEqual(beas.map(\.id), [f.alfred.id])
        XCTAssertEqual(graces, [], "The other Hub is left alone")
        let after = await hubs.sharing(of: f.alfred.id)
        XCTAssertEqual(after.map(\.sharedWith), [[], [studio.bea.id]])
        do {
            try await hubs.share(f.alfred, onHub: "not one of them", with: [studio.bea.id])
            XCTFail("Shared on a Hub this Mac did not join")
        } catch {}
    }

    /// A Hub out of reach is left out, without holding up the others, unless its people are already known here.
    func testAHubOutOfReachIsLeftOutUnlessItsPeopleAreKnown() async throws {
        let f = try await fixture()
        let studio = try await secondHub(f)
        let hubs = [HubMirror(pairing: f.mac, repository: f.local, directory: f.folder),
                    HubMirror(pairing: studio.mac, repository: f.local, directory: studio.folder)]
        studio.link.stop()
        let asked = ContinuousClock.now
        let listed = await hubs.sharing(of: f.alfred.id)
        XCTAssertEqual(listed.map(\.name), ["Mac mini"])
        // Generous for CI: a Hub that does not answer holds the list only briefly, not until its connection gives up.
        XCTAssertLessThan(ContinuousClock.now - asked, .seconds(10))

        _ = try await hubs[0].sharing(of: f.alfred.id)
        f.link.stop()
        let known = await hubs.sharing(of: f.alfred.id)
        XCTAssertEqual(known.map(\.name), ["Mac mini"], "Known people are shown while the Hub is away")
        XCTAssertEqual(known.first?.people.map(\.name), ["Grace"])
    }

    /// People are fetched once and kept: asked again they come at once, and once they are a while old,
    /// still at once while newer ones are fetched for next time.
    func testPeopleAreKeptAndRefreshedInTheBackground() async throws {
        let f = try await fixture()
        let mirror = HubMirror(pairing: f.mac, repository: f.local, directory: f.folder)
        var now = Date(timeIntervalSince1970: 1_000_000)
        mirror.now = { now }
        let first = try await mirror.sharing(of: f.alfred.id)
        XCTAssertEqual(first.people.map(\.name), ["Grace"])
        _ = try f.hub.access.addUser(named: "Bea")
        let kept = try await mirror.sharing(of: f.alfred.id)
        XCTAssertEqual(kept.people.map(\.name), ["Grace"], "Kept, not fetched again")

        now += HubMirror.peopleKeptFor + 1
        let stale = try await mirror.sharing(of: f.alfred.id)
        XCTAssertEqual(stale.people.map(\.name), ["Grace"], "What is kept comes at once")
        for _ in 0..<100 {
            if try await mirror.sharing(of: f.alfred.id).people.count == 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let fresh = try await mirror.sharing(of: f.alfred.id)
        XCTAssertEqual(Set(fresh.people.map(\.name)), ["Grace", "Bea"], "Fetched again for next time")
    }

    /// The Mac's copy of its Hub never takes a bot it hosts for one of the Hub's own.
    func testAHostedBotIsNotCopiedAsAHubBot() async throws {
        let f = try await fixture()
        let mirror = HubMirror(pairing: f.mac, repository: f.local, directory: f.folder)
        try await mirror.hosting.share(f.alfred, with: [f.grace.id])
        await mirror.sync()
        await mirror.hosting.sync()
        XCTAssertEqual(mirror.localAgentIDs, [])
        XCTAssertEqual(try f.local.loadAgents().map(\.id), [f.alfred.id])
    }
}
