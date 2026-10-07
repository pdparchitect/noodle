import Foundation
import HubCore
import HubLink
import NoodleCore
import XCTest

/// A bot that runs on its owner's Mac, which the Hub keeps the conversations of for the people it
/// is shared with, over real QUIC on this Mac.
@MainActor final class HubHostedBotsTests: XCTestCase {
    private struct Fixture {
        let hub: Hub
        let link: HubLinkService
        let ada: HubUser
        /// Ada's Mac, which hosts the bot.
        let mac: HubPairing
        let grace: HubUser
        let gracesPhone: HubPairing
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-hosted-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(root: root.appendingPathComponent("Hub"), messenger: nil)
        try hub.repository.prepare()
        let link = HubLinkService(hubName: "Mac mini", directory: root.appendingPathComponent("Hub/Link"),
                                  access: hub.access, profiles: hub.harnessProfiles, bots: hub.bots, port: 0,
                                  localEndpoints: { [LinkEndpoint(host: "::1", port: $0)] }, pushDelay: .zero)
        await link.start()
        addTeardownBlock { await MainActor.run { link.stop() } }
        guard case .listening = link.state else { throw XCTSkip("Could not listen: \(link.state)") }
        let ada = try hub.access.addUser(named: "Ada")
        let mac = try await device("Mac", of: ada, root: root, link: link)
        let grace = try hub.access.addUser(named: "Grace")
        let phone = try await device("Grace", of: grace, root: root, link: link)
        return Fixture(hub: hub, link: link, ada: ada, mac: mac, grace: grace, gracesPhone: phone)
    }

    private func device(_ name: String, of user: HubUser, root: URL, link: HubLinkService) async throws -> HubPairing {
        let device = HubPairing(directory: root.appendingPathComponent("Devices/\(UUID())"), deviceName: name)
        await device.join(link.invite(user).url().absoluteString)
        XCTAssertNil(device.error)
        return device
    }

    /// Ada's Mac publishes its bot and shares it with Grace.
    private func host(_ f: Fixture, id: UUID = UUID(), name: String = "Alfred") async throws -> UUID {
        guard case .hostedBot(let bot) = try await f.mac.request(.host(.publish(id: id, LinkBotDraft(name: name, provider: "")))) else {
            throw XCTSkip("unexpected answer")
        }
        XCTAssertEqual(bot.id, id)
        _ = try await f.mac.request(.shareBot(id: id, people: [f.grace.id]))
        return id
    }

    private func bots(of device: HubPairing) async throws -> [LinkBot] {
        guard case .bots(let bots) = try await device.request(.bots) else { throw XCTSkip("unexpected answer") }
        return bots
    }

    private func hosted(by device: HubPairing) async throws -> [LinkHostedBot] {
        guard case .hostedBots(let bots) = try await device.request(.host(.bots)) else { throw XCTSkip("unexpected answer") }
        return bots
    }

    private func messages(in conversation: UUID, of device: HubPairing) async throws -> [LinkMessage] {
        guard case .messages(let page) = try await device.request(.messagePage(LinkMessagePage(conversationID: conversation, after: 0))) else {
            throw XCTSkip("unexpected answer")
        }
        return page.messages
    }

    private func hostMessages(in conversation: UUID, of device: HubPairing) async throws -> [LinkMessage] {
        guard case .messages(let page) = try await device.request(.host(.messagePage(LinkMessagePage(conversationID: conversation, after: 0)))) else {
            throw XCTSkip("unexpected answer")
        }
        return page.messages
    }

    /// Waits for the first event `matches` accepts, failing rather than waiting forever when none comes.
    private func expect(_ what: String, in events: AsyncThrowingStream<LinkEvent, Error>, file: StaticString = #filePath,
                        line: UInt = #line, where matches: @escaping @Sendable (LinkEvent) -> Bool) async throws {
        let heard = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                for try await event in events where matches(event) { return true }
                return false
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                return false
            }
            let first = try await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !heard { XCTFail("Never heard \(what)", file: file, line: line) }
    }

    /// Grace talks with Ada's bot in her own conversation on the Hub, as with any bot shared with her.
    /// Her messages are kept while the Mac is away; the Mac reads them, replies and marks them taken.
    func testPeopleTalkWithABotItsOwnersMacHosts() async throws {
        let f = try await fixture()
        let id = try await host(f)
        XCTAssertTrue(f.hub.runtime.remoteAgentIDs.contains(id), "The Hub never runs a bot its owner's Mac hosts")
        XCTAssertNil(try f.hub.repository.loadAgents().first { $0.id == id }?.harnessIdentifier)
        let adas = try await bots(of: f.mac)
        XCTAssertEqual(adas, [], "A hosted bot is not one of its owner's Hub bots")

        guard let graces = try await bots(of: f.gracesPhone).first else { return XCTFail("not shared") }
        XCTAssertEqual(graces.id, id)
        XCTAssertEqual(graces.owner, "Ada")
        XCTAssertEqual(graces.draft.name, "Alfred")
        XCTAssertEqual(graces.phase, .offline, "Nothing reports it while the Mac is away")
        XCTAssertFalse(graces.canCall)
        let hostedHere = try await hosted(by: f.mac)
        XCTAssertEqual(hostedHere,
                       [LinkHostedBot(id: id, conversations: [LinkGuestConversation(id: graces.conversationID, person: f.grace.id, name: "Grace")])])

        let hello = UUID()
        _ = try await f.gracesPhone.request(.send(LinkOutgoingMessage(conversationID: graces.conversationID, id: hello, body: "Hello")))
        let waiting = try await hostMessages(in: graces.conversationID, of: f.mac)
        XCTAssertEqual(waiting.map(\.body), ["Hello"])
        XCTAssertEqual(waiting.first?.author, .you)
        XCTAssertEqual(waiting.first?.delivered, false)

        _ = try await f.mac.request(.host(.delivered(conversationID: graces.conversationID, messageIDs: [hello])))
        let reply = LinkHostedReply(conversationID: graces.conversationID, id: UUID(), body: "Good evening, Grace.")
        guard case .message(let sent) = try await f.mac.request(.host(.reply(reply))) else { return XCTFail("not sent") }
        XCTAssertEqual(sent.author, .bot(id))
        _ = try await f.mac.request(.host(.reply(reply)))
        let seen = try await messages(in: graces.conversationID, of: f.gracesPhone)
        XCTAssertEqual(seen.map(\.body), ["Hello", "Good evening, Grace."], "A reply sent again is kept once")
        XCTAssertEqual(seen.first?.delivered, true)
        XCTAssertEqual(seen.last?.author, .bot(id))
    }

    /// Only the Mac that published a bot asks about it: not its owner's other devices, nor anyone else,
    /// and it reaches nothing else on the Hub that way.
    func testOnlyTheHostingDeviceReachesItsBot() async throws {
        let f = try await fixture()
        let id = try await host(f)
        guard let graces = try await bots(of: f.gracesPhone).first else { return XCTFail("not shared") }
        let root = f.mac.directory.deletingLastPathComponent().deletingLastPathComponent()
        let adasPhone = try await device("iPhone", of: f.ada, root: root, link: f.link)
        let file = LinkAttachment(id: UUID(), filename: "a.txt", mediaType: "text/plain", byteCount: 1)
        let refused: [LinkHostRequest] = [
            .publish(id: id, LinkBotDraft(name: "Mine", provider: "")),
            .messagePage(LinkMessagePage(conversationID: graces.conversationID, after: 0)),
            .download(conversationID: graces.conversationID, attachmentID: UUID(), offset: 0),
            .upload(conversationID: graces.conversationID, attachment: file, offset: 0, data: Data([1])),
            .reply(LinkHostedReply(conversationID: graces.conversationID, id: UUID(), body: "Hi")),
            .delivered(conversationID: graces.conversationID, messageIDs: []),
            .phase(botID: id, phase: .ready),
            .react(LinkReactionChange(conversationID: graces.conversationID, messageID: UUID(), emoji: "👍", present: true)),
            .effect(conversationID: graces.conversationID, id: UUID(), kind: "confetti"),
        ]
        for (name, device) in [("Ada's phone", adasPhone), ("Grace", f.gracesPhone)] {
            for request in refused {
                do {
                    _ = try await device.request(.host(request))
                    XCTFail("\(name) reached a bot it does not host: \(request)")
                } catch {}
            }
            let theirs = try await hosted(by: device)
            XCTAssertEqual(theirs, [])
        }
        let untouched = try await messages(in: graces.conversationID, of: f.gracesPhone)
        XCTAssertEqual(untouched, [])

        // Publishing never takes over a bot the Hub runs, nor reads its conversations.
        let plan = try f.hub.access.addPlan(named: "Family")
        f.hub.access.set(HubHarness(provider: .claudeCode, profile: nil), included: true, in: plan)
        f.hub.access.move(f.ada, to: plan)
        guard case .bot(let hubBot) = try await f.mac.request(.createBot(LinkBotDraft(name: "Jeeves", provider: "claude-code"))) else {
            return XCTFail("no bot")
        }
        for request in [LinkHostRequest.publish(id: hubBot.id, LinkBotDraft(name: "Mine", provider: "")),
                        .messagePage(LinkMessagePage(conversationID: hubBot.conversationID, after: 0)),
                        .reply(LinkHostedReply(conversationID: hubBot.conversationID, id: UUID(), body: "Hi"))] {
            do {
                _ = try await f.mac.request(.host(request))
                XCTFail("Reached a Hub bot as if hosting it: \(request)")
            } catch {}
        }
        XCTAssertEqual(try f.hub.repository.loadAgents().first { $0.id == hubBot.id }?.harnessIdentifier, "claude-code")
    }

    /// Sharing through other Hubs is for the owner's own Mac; a Noodle Hub shares its bots itself.
    func testANoodleHubSharesNothingThroughOtherHubs() async throws {
        let f = try await fixture()
        let id = try await host(f)
        for request in [LinkRequest.hubSharing(botID: id), .shareOnHub(botID: id, hub: "other", people: [])] {
            do {
                _ = try await f.mac.request(request)
                XCTFail("A Noodle Hub shared through other Hubs: \(request)")
            } catch {}
        }
    }

    /// The Hub runs nothing of a hosted bot and manages it only as far as sharing, archiving and deleting.
    func testAHostedBotIsNotRunOrEditedOnTheHub() async throws {
        let f = try await fixture()
        let id = try await host(f)
        let refused: [LinkRequest] = [
            .updateBot(id: id, LinkBotDraft(name: "Jeeves", provider: "claude-code")),
            .kick(botID: id), .newSession(botID: id), .confirmKick(botID: id, confirmationID: UUID()),
            .createGroup(LinkGroupDraft(name: "House", botIDs: [id])),
        ]
        for request in refused {
            do {
                _ = try await f.mac.request(request)
                XCTFail("Ran or edited a hosted bot on the Hub: \(request)")
            } catch {}
        }

        // Archived, Grace no longer sees it; brought back, her conversation is there again.
        guard let before = try await bots(of: f.gracesPhone).first else { return XCTFail("not shared") }
        _ = try await f.mac.request(.archive(LinkArchiveChange(id: id, archived: true)))
        let whileArchived = try await bots(of: f.gracesPhone)
        XCTAssertEqual(whileArchived, [])
        _ = try await f.mac.request(.archive(LinkArchiveChange(id: id, archived: false)))
        let back = try await bots(of: f.gracesPhone)
        XCTAssertEqual(back.first?.conversationID, before.conversationID)

        // A new name and picture reach Grace.
        guard case .hostedBot = try await f.mac.request(.host(.publish(id: id, LinkBotDraft(name: "Jeeves", provider: "",
                                                                                             avatarSymbolName: "cup.and.saucer")))) else {
            return XCTFail("not changed")
        }
        let renamed = try await bots(of: f.gracesPhone).first
        XCTAssertEqual(renamed?.draft.name, "Jeeves")
        XCTAssertEqual(renamed?.draft.avatarSymbolName, "cup.and.saucer")

        _ = try await f.mac.request(.deleteBot(id: id))
        let afterwards = try await bots(of: f.gracesPhone)
        XCTAssertEqual(afterwards, [])
        XCTAssertTrue(try f.hub.repository.loadConversations().isEmpty)
        let nothingHosted = try await hosted(by: f.mac)
        XCTAssertEqual(nothingHosted, [])
        XCTAssertFalse(f.hub.runtime.remoteAgentIDs.contains(id))
    }

    /// Grace sees the bot online, and what it is doing, only while Ada's Mac is connected.
    func testAHostedBotIsOnlineWhileItsMacIsConnected() async throws {
        let f = try await fixture()
        let id = try await host(f)
        let events = try await f.gracesPhone.subscribe()
        _ = try await f.gracesPhone.request(.bots)
        f.hub.bots.checkForChanges()

        let macEvents = try await f.mac.subscribe()
        let following = Task { for try await _ in macEvents {} }
        _ = try await f.mac.request(.host(.phase(botID: id, phase: .working)))
        try await expect("that it works", in: events) { if case .botPhase(id, .working) = $0 { true } else { false } }
        let working = try await bots(of: f.gracesPhone)
        XCTAssertEqual(working.first?.phase, .working)

        following.cancel()
        try await expect("that it went offline", in: events) { if case .botPhase(id, .offline) = $0 { true } else { false } }
        let offline = try await bots(of: f.gracesPhone)
        XCTAssertEqual(offline.first?.phase, .offline)
    }

    /// The Mac hears when Grace writes, and her conversation reaches none of Ada's other devices.
    func testTheHostingMacHearsOfNewMessages() async throws {
        let f = try await fixture()
        _ = try await host(f)
        guard let graces = try await bots(of: f.gracesPhone).first else { return XCTFail("not shared") }
        let root = f.mac.directory.deletingLastPathComponent().deletingLastPathComponent()
        let adasPhone = try await device("iPhone", of: f.ada, root: root, link: f.link)
        let macEvents = try await f.mac.subscribe()
        let phoneEvents = try await adasPhone.subscribe()
        _ = try await f.mac.request(.status)
        f.hub.bots.checkForChanges()

        _ = try await f.gracesPhone.request(.send(LinkOutgoingMessage(conversationID: graces.conversationID, id: UUID(), body: "Hello")))
        f.hub.bots.checkForChanges()
        let conversation = graces.conversationID
        try await expect("Grace's message", in: macEvents) { if case .conversationChanged(conversation, 1) = $0 { true } else { false } }

        // Ada's phone hears of something of her own, and never of Grace's conversation before it.
        _ = try await adasPhone.request(.setAvatar(LinkAvatar(colour: 2)))
        let heard = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                for try await event in phoneEvents {
                    if case .conversationChanged(conversation, _) = event { return true }
                    if case .usersChanged = event { return false }
                }
                return false
            }
            group.addTask { try await Task.sleep(for: .seconds(2)); return false }
            let first = try await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertFalse(heard, "Ada's phone heard of Grace's conversation")
    }

    /// Reactions travel both ways: the bot's, from the Mac, reach Grace, and the Mac hears of hers.
    func testReactionsTravelBothWays() async throws {
        let f = try await fixture()
        let id = try await host(f)
        guard let graces = try await bots(of: f.gracesPhone).first else { return XCTFail("not shared") }
        let hello = UUID()
        _ = try await f.gracesPhone.request(.send(LinkOutgoingMessage(conversationID: graces.conversationID, id: hello, body: "Hello")))
        let thumbs = LinkReactionChange(conversationID: graces.conversationID, messageID: hello, emoji: "👍", present: true)
        guard case .message(let reacted) = try await f.mac.request(.host(.react(thumbs))) else { return XCTFail("not reacted") }
        XCTAssertEqual(reacted.reactions, [LinkReaction(author: .bot(id), emoji: "👍")])
        let seen = try await messages(in: graces.conversationID, of: f.gracesPhone)
        XCTAssertEqual(seen.first?.reactions, [LinkReaction(author: .bot(id), emoji: "👍")])

        let reply = LinkHostedReply(conversationID: graces.conversationID, id: UUID(), body: "Good evening.")
        _ = try await f.mac.request(.host(.reply(reply)))
        let macEvents = try await f.mac.subscribe()
        _ = try await f.mac.request(.status)
        f.hub.bots.checkForChanges()
        _ = try await f.gracesPhone.request(.react(LinkReactionChange(conversationID: graces.conversationID, messageID: reply.id,
                                                                      emoji: "❤️", present: true)))
        let replyID = reply.id
        try await expect("Grace's reaction", in: macEvents) {
            if case .messageChanged(let message) = $0 { message.id == replyID && message.reactions == [LinkReaction(author: .you, emoji: "❤️")] }
            else { false }
        }
        do {
            _ = try await f.mac.request(.host(.react(LinkReactionChange(conversationID: graces.conversationID, messageID: hello,
                                                                        emoji: "not one", present: true))))
            XCTFail("Took a reaction that is not an emoji")
        } catch {}
    }

    /// A chat effect the bot sends from the Mac waits on the Hub for Grace to see her conversation.
    func testAChatEffectFromTheMacWaitsForThePerson() async throws {
        let f = try await fixture()
        _ = try await host(f)
        guard let graces = try await bots(of: f.gracesPhone).first else { return XCTFail("not shared") }
        let events = try await f.gracesPhone.subscribe()
        _ = try await f.gracesPhone.request(.status)
        f.hub.bots.checkForChanges()
        let id = UUID()
        _ = try await f.mac.request(.host(.effect(conversationID: graces.conversationID, id: id, kind: "fireworks")))
        _ = try await f.mac.request(.host(.effect(conversationID: graces.conversationID, id: id, kind: "fireworks")))
        let conversation = graces.conversationID
        try await expect("that an effect waits", in: events) { if case .effectWaiting(conversation) = $0 { true } else { false } }
        let taken = try await f.gracesPhone.request(.takeEffect(conversationID: graces.conversationID))
        XCTAssertEqual(taken, .effect(LinkEffect(id: id, kind: "fireworks")))
        do {
            _ = try await f.mac.request(.host(.effect(conversationID: graces.conversationID, id: UUID(), kind: "shell")))
            XCTFail("Took an effect no app draws")
        } catch {}
    }

    /// Files travel both ways, and links too, except those that open live on the Mac.
    func testFilesAndLinksTravelBothWays() async throws {
        let f = try await fixture()
        _ = try await host(f)
        guard let graces = try await bots(of: f.gracesPhone).first else { return XCTFail("not shared") }
        let photo = LinkAttachment(id: UUID(), filename: "cat.txt", mediaType: "text/plain", byteCount: 3)
        _ = try await f.gracesPhone.request(.upload(conversationID: graces.conversationID, attachment: photo, offset: 0, data: Data("cat".utf8)))
        _ = try await f.gracesPhone.request(.send(LinkOutgoingMessage(conversationID: graces.conversationID, id: UUID(), body: "Look",
                                                                      attachmentIDs: [photo.id])))
        let waiting = try await hostMessages(in: graces.conversationID, of: f.mac)
        XCTAssertEqual(waiting.first?.attachments.map(\.id), [photo.id])
        guard case .chunk(let data, let total) = try await f.mac.request(.host(.download(conversationID: graces.conversationID,
                                                                                            attachmentID: photo.id, offset: 0))) else {
            return XCTFail("not downloaded")
        }
        XCTAssertEqual(data, Data("cat".utf8))
        XCTAssertEqual(total, 3)

        let drawing = LinkAttachment(id: UUID(), filename: "dog.txt", mediaType: "text/plain", byteCount: 3)
        _ = try await f.mac.request(.host(.upload(conversationID: graces.conversationID, attachment: drawing, offset: 0, data: Data("dog".utf8))))
        let page = LinkAttachment(id: UUID(), filename: "Example", mediaType: "application/x-webloc", byteCount: 0,
                                  url: URL(string: "https://example.com/tea")!)
        _ = try await f.mac.request(.host(.reply(LinkHostedReply(conversationID: graces.conversationID, id: UUID(), body: "Here",
                                                                 attachmentIDs: [drawing.id], links: [page]))))
        let reply = try await messages(in: graces.conversationID, of: f.gracesPhone).last
        XCTAssertEqual(reply?.body, "Here")
        XCTAssertEqual(reply?.attachments.map(\.id), [drawing.id, page.id])
        XCTAssertEqual(reply?.attachments.last?.url, URL(string: "https://example.com/tea"))
        guard case .chunk(let got, _) = try await f.gracesPhone.request(.download(conversationID: graces.conversationID,
                                                                                  attachmentID: drawing.id, offset: 0)) else {
            return XCTFail("not downloaded")
        }
        XCTAssertEqual(got, Data("dog".utf8))

        let live = LinkAttachment(id: UUID(), filename: "Noodlet", mediaType: "application/x-webloc", byteCount: 0,
                                  url: CompanionLink.noodlet(UUID()).url)
        do {
            _ = try await f.mac.request(.host(.reply(LinkHostedReply(conversationID: graces.conversationID, id: UUID(), body: "Play",
                                                                     links: [live]))))
            XCTFail("Sent a link that opens live on the Mac")
        } catch {}
    }

    /// A bot goes from the Hub with the Mac that hosts it, and with its owner.
    func testAHostedBotGoesWithItsMac() async throws {
        let f = try await fixture()
        let id = try await host(f)
        let mac = try XCTUnwrap(f.hub.access.devices.first { $0.user == f.ada.id })
        f.hub.access.remove(mac)
        for _ in 0..<50 where try f.hub.repository.loadAgents().contains(where: { $0.id == id }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(try f.hub.repository.loadAgents().contains { $0.id == id })
        XCTAssertTrue(try f.hub.repository.loadConversations().isEmpty)
        let gone = try await bots(of: f.gracesPhone)
        XCTAssertEqual(gone, [])
    }
}
