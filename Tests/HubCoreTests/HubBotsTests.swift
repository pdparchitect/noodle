import AppKit
import Foundation
import HubCore
import HubLink
import NoodleCore
import XCTest

/// A paired device keeping a bot on the Hub, over real QUIC on this Mac.
@MainActor final class HubBotsTests: XCTestCase {
    private struct Fixture {
        let hub: Hub
        let link: HubLinkService
        let ada: HubUser
        let device: HubPairing
        /// Where the Hub keeps files still arriving.
        let uploads: URL
    }

    private let claude = HubHarness(provider: .claudeCode, profile: nil)

    /// Stands in for CloudKit, keeping what the Hub asked it to show.
    private actor RecordedPushes: HubPushPublisher {
        var shown: [String: Int] = [:]
        var published: [String] = []

        private func key(_ topic: String, _ conversation: UUID) -> String { "\(topic) \(conversation)" }

        func publish(topic: String, conversation: UUID, unread: Int) {
            shown[key(topic, conversation)] = unread
            published.append(key(topic, conversation))
        }

        func withdraw(topic: String, conversation: UUID) { shown[key(topic, conversation)] = nil }

        func unread(_ topic: String, _ conversation: UUID) -> Int? { shown[key(topic, conversation)] }
    }

    private func fixture(pushes: RecordedPushes? = nil) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-bots-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(root: root.appendingPathComponent("Hub"), messenger: nil)
        try hub.repository.prepare()
        let link = HubLinkService(hubName: "Mac mini", directory: root.appendingPathComponent("Hub/Link"),
                                  access: hub.access, profiles: hub.harnessProfiles, bots: hub.bots,
                                  connections: hub.connections, port: 0,
                                  localEndpoints: { [LinkEndpoint(host: "::1", port: $0)] },
                                  pushes: pushes, pushDelay: .zero)
        await link.start()
        addTeardownBlock { await MainActor.run { link.stop() } }
        guard case .listening = link.state else { throw XCTSkip("Could not listen: \(link.state)") }
        let family = try hub.access.addPlan(named: "Family")
        hub.access.set(claude, included: true, in: family)
        let ada = try hub.access.addUser(named: "Ada")
        hub.access.move(ada, to: family)
        let device = HubPairing(directory: root.appendingPathComponent("Device"), deviceName: "Mac")
        await device.join(link.invite(ada).url().absoluteString)
        XCTAssertNil(device.error)
        return Fixture(hub: hub, link: link, ada: ada, device: device,
                       uploads: root.appendingPathComponent("Hub/Uploads", isDirectory: true))
    }

    private func createBot(_ f: Fixture, provider: String = "claude-code") async throws -> LinkBot {
        guard case .bot(let bot) = try await f.device.request(.createBot(LinkBotDraft(name: "Alfred", provider: provider,
                                                                                     backstory: "A butler."))) else {
            throw XCTSkip("unexpected answer")
        }
        return bot
    }

    func testABotIsCreatedOnTheHubForItsUser() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        XCTAssertEqual(bot.draft.name, "Alfred")
        let agent = try XCTUnwrap(f.hub.repository.loadAgents().first { $0.id == bot.id })
        XCTAssertEqual(agent.harnessIdentifier, "claude-code")
        XCTAssertEqual(try f.hub.repository.loadAgentBackstory(agent), "A butler.")
        XCTAssertEqual(f.hub.access.owner(ofBot: bot.id), f.ada.id)
        let listed = try await f.device.request(.bots)
        XCTAssertEqual(listed, .bots([bot]))
    }

    /// The list leaves a bot's picture out; a device fetches it once, and an edit keeps it without sending it back.
    func testBotPicturesTravelApartFromTheList() async throws {
        let f = try await fixture()
        let picture = Data(repeating: 9, count: 300_000)
        guard case .bot(let bot) = try await f.device.request(.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code",
                                                                                     avatarImageData: picture))) else {
            return XCTFail("unexpected answer")
        }
        guard case .bots(let listed) = try await f.device.request(.bots) else { return XCTFail("unexpected answer") }
        let draft = try XCTUnwrap(listed.first?.draft)
        XCTAssertNil(draft.avatarImageData)
        XCTAssertEqual(draft.avatarImageDigest, LinkPicture.digest(picture))
        XCTAssertNil(f.device.keptPictures(listed).first?.draft.avatarImageData)
        await f.device.fetchPictures(listed)
        XCTAssertEqual(f.device.keptPictures(listed).first?.draft.avatarImageData, picture)

        var renamed = try XCTUnwrap(f.device.keptPictures(listed).first?.draft)
        renamed.name = "Jeeves"
        XCTAssertNil(renamed.leavingOutKnownPicture.avatarImageData)
        _ = try await f.device.request(.updateBot(id: bot.id, renamed.leavingOutKnownPicture))
        let agent = { try XCTUnwrap(f.hub.repository.loadAgents().first { $0.id == bot.id }) }
        XCTAssertEqual(try agent().displayName, "Jeeves")
        XCTAssertEqual(try agent().avatarImageData, picture)

        var symbol = renamed
        symbol.removePicture()
        _ = try await f.device.request(.updateBot(id: bot.id, symbol.leavingOutKnownPicture))
        XCTAssertNil(try agent().avatarImageData)
    }

    func testBotsOnlyUseHarnessesTheirUsersPlanLends() async throws {
        let f = try await fixture()
        do {
            _ = try await createBot(f, provider: "codex")
            XCTFail("Created a bot on a harness the plan does not lend")
        } catch {
            XCTAssertEqual((error as? LinkError)?.message, "Your plan does not lend Codex.")
        }
        XCTAssertTrue(try f.hub.repository.loadAgents().isEmpty)
    }

    func testBotsOnlyUseModelsTheirUsersPlanLends() async throws {
        let f = try await fixture()
        f.hub.access.setModels(["sonnet"], for: claude, in: f.hub.access.plans[1])
        for model in [nil, "opus"] {
            do {
                _ = try await f.device.request(.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code", model: model)))
                XCTFail("Created a bot on a model the plan does not lend")
            } catch {
                XCTAssertEqual((error as? LinkError)?.message,
                               model.map { "Your plan does not lend \($0) on Claude Code." } ?? "Your plan needs a model chosen for Claude Code.")
            }
        }
        guard case .bot(let bot) = try await f.device.request(.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code",
                                                                                     model: "sonnet"))) else {
            return XCTFail("unexpected answer")
        }
        f.hub.access.setModels(["haiku"], for: claude, in: f.hub.access.plans[1])
        do {
            _ = try await f.device.request(.send(LinkOutgoingMessage(conversationID: bot.conversationID, id: UUID(), body: "Hi", attachmentIDs: [])))
            XCTFail("Sent through a model the plan no longer lends")
        } catch {
            XCTAssertEqual((error as? LinkError)?.message, "Your plan no longer lends sonnet on Claude Code.")
        }
    }

    func testTheStatusSaysWhichModelsThePlanLends() async throws {
        let f = try await fixture()
        f.hub.access.setModels(["opus", "haiku"], for: claude, in: f.hub.access.plans[1])
        await f.device.refresh()
        let harness = try XCTUnwrap(f.device.status?.harnesses.first)
        XCTAssertTrue(harness.restrictsModels)
        XCTAssertEqual(harness.models.map(\.id), ["haiku", "opus"])
    }

    func testSendingTwiceWithOneIDKeepsOneMessage() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        let id = UUID()
        _ = try await f.device.request(.send(LinkOutgoingMessage(conversationID: bot.conversationID, id: id, body: "Hello", attachmentIDs: [])))
        _ = try await f.device.request(.send(LinkOutgoingMessage(conversationID: bot.conversationID, id: id, body: "Hello", attachmentIDs: [])))
        guard case .messages(let page) = try await f.device.request(.messages(conversationID: bot.conversationID, after: 0)) else {
            return XCTFail("no messages")
        }
        XCTAssertEqual(page.messages.map(\.id), [id])
        XCTAssertEqual(page.messages.first?.author, .you)
        XCTAssertEqual(page.count, 1)
    }

    func testBotRepliesArePushedToTheOwnersDevices() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        let events = try await f.device.subscribe()
        _ = try await f.device.request(.send(LinkOutgoingMessage(conversationID: bot.conversationID, id: UUID(), body: "Hello", attachmentIDs: [])))
        _ = try f.hub.repository.sendAgentMessage(agentID: bot.id, conversationID: bot.conversationID, body: "Good evening.")
        f.hub.bots.checkForChanges()

        var counts: [Int] = []
        for try await event in events {
            if case .conversationChanged(bot.conversationID, let count) = event { counts.append(count) }
            if counts.last == 2 { break }
        }
        XCTAssertEqual(counts.last, 2)
        guard case .messages(let page) = try await f.device.request(.messages(conversationID: bot.conversationID, after: 1)) else {
            return XCTFail("no messages")
        }
        XCTAssertEqual(page.messages.map(\.body), ["Good evening."])
        XCTAssertEqual(page.messages.first?.author, .bot(bot.id))
    }

    /// Reading on one device reads on all of the user's devices, and a device that joins later starts from it.
    func testReadingIsKeptOnTheHub() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        _ = try await f.device.request(.send(LinkOutgoingMessage(conversationID: bot.conversationID, id: UUID(), body: "Hello")))
        _ = try f.hub.repository.sendAgentMessage(agentID: bot.id, conversationID: bot.conversationID, body: "Done.")
        XCTAssertNil(bot.readUpTo)
        // Dates as a device has them, having crossed the link.
        guard case .messages(let page) = try await f.device.request(.messages(conversationID: bot.conversationID, after: 0)),
              let hello = page.messages.first, let reply = page.messages.last, page.messages.count == 2 else {
            return XCTFail("no messages")
        }
        let phone = HubPairing(directory: FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-phone-\(UUID())"),
                               deviceName: "Phone")
        await phone.join(f.link.invite(f.ada).url().absoluteString)
        let events = try await phone.subscribe()

        let read = LinkReadMark(conversationID: bot.conversationID, messageID: reply.id)
        let answer = try await f.device.request(.markRead(read))
        XCTAssertEqual(answer, .done)
        var heard: Date?
        for try await event in events {
            if case .readChanged(bot.conversationID, let upTo) = event { heard = upTo; break }
        }
        XCTAssertEqual(heard, reply.createdAt)

        // An older mark, from a device that fell behind, does not unread what was read.
        _ = try await phone.request(.markRead(LinkReadMark(conversationID: bot.conversationID, messageID: hello.id)))
        guard case .bots(let listed) = try await phone.request(.bots) else { return XCTFail("no bots") }
        XCTAssertEqual(listed.first?.readUpTo, reply.createdAt)
        do {
            _ = try await phone.request(.markRead(LinkReadMark(conversationID: bot.conversationID, messageID: UUID())))
            XCTFail("Read a message that is not there")
        } catch {}

        let grace = try f.hub.access.addUser(named: "Grace")
        let other = HubPairing(directory: FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-other-\(UUID())"),
                               deviceName: "Other")
        await other.join(f.link.invite(grace).url().absoluteString)
        do {
            _ = try await other.request(.markRead(read))
            XCTFail("Read another user's conversation")
        } catch {}
    }

    /// A device away from the Hub hears of unread replies, and they go away once read on any device.
    /// Replies already there when the Hub starts watching, and replies to a device that is connected, push nothing.
    func testUnreadRepliesArePushedToDevicesAway() async throws {
        let pushes = RecordedPushes()
        let f = try await fixture(pushes: pushes)
        let bot = try await createBot(f)
        _ = try f.hub.repository.sendAgentMessage(agentID: bot.id, conversationID: bot.conversationID, body: "Already here.")
        let answer = try await f.device.request(.pushTopic(LinkPushTopic(topic: "phone-topic")))
        XCTAssertEqual(answer, .done)
        f.hub.bots.checkForChanges()

        let reply = try f.hub.repository.sendAgentMessage(agentID: bot.id, conversationID: bot.conversationID, body: "Done.")
        f.hub.bots.checkForChanges()
        for _ in 0..<50 where await pushes.unread("phone-topic", bot.conversationID) != 2 { try await Task.sleep(for: .milliseconds(100)) }
        let unread = await pushes.unread("phone-topic", bot.conversationID)
        XCTAssertEqual(unread, 2)
        let publishedOnce = await pushes.published.count
        XCTAssertEqual(publishedOnce, 1)

        _ = try await f.device.request(.markRead(LinkReadMark(conversationID: bot.conversationID, messageID: reply.id)))
        for _ in 0..<50 where await pushes.unread("phone-topic", bot.conversationID) != nil { try await Task.sleep(for: .milliseconds(100)) }
        let afterReading = await pushes.unread("phone-topic", bot.conversationID)
        XCTAssertNil(afterReading)

        // Connected, the device shows replies itself.
        let events = try await f.device.subscribe()
        _ = try await f.device.request(.bots)
        _ = events
        _ = try f.hub.repository.sendAgentMessage(agentID: bot.id, conversationID: bot.conversationID, body: "Anything else?")
        f.hub.bots.checkForChanges()
        try await Task.sleep(for: .milliseconds(300))
        let whileConnected = await pushes.published.count
        XCTAssertEqual(whileConnected, 1)
    }

    func testReactionsTravelBothWays() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        let events = try await f.device.subscribe()
        let reply = try f.hub.repository.sendAgentMessage(agentID: bot.id, conversationID: bot.conversationID, body: "Done.")
        f.hub.bots.checkForChanges()

        guard case .message(let reacted) = try await f.device.request(.react(LinkReactionChange(
            conversationID: bot.conversationID, messageID: reply.id, emoji: "👍", present: true))) else {
            return XCTFail("no message")
        }
        XCTAssertEqual(reacted.reactions, [LinkReaction(author: .you, emoji: "👍")])
        XCTAssertEqual(try f.hub.repository.loadMessages(conversationID: bot.conversationID).first?.reactions?.map(\.emoji), ["👍"])

        // The bot reacts through the messenger; the owner's devices hear about it.
        _ = try f.hub.repository.setReaction(conversationID: bot.conversationID, messageID: reply.id,
                                             author: .agent(bot.id), emoji: "🎉", present: true)
        f.hub.bots.checkForChanges()
        var changed: LinkMessage?
        for try await event in events {
            if case .messageChanged(let message) = event, message.reactions.contains(LinkReaction(author: .bot(bot.id), emoji: "🎉")) {
                changed = message
                break
            }
        }
        XCTAssertEqual(changed?.id, reply.id)
        XCTAssertEqual(changed?.reactions.count, 2)

        guard case .message(let removed) = try await f.device.request(.react(LinkReactionChange(
            conversationID: bot.conversationID, messageID: reply.id, emoji: "👍", present: false))) else {
            return XCTFail("no message")
        }
        XCTAssertEqual(removed.reactions, [LinkReaction(author: .bot(bot.id), emoji: "🎉")])
    }

    func testBotsSayWhatTheyAreDoing() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        // The runtime is not started here, so the bot is offline.
        XCTAssertEqual(bot.phase, .offline)
        guard case .bots(let listed) = try await f.device.request(.bots) else { return XCTFail("no bots") }
        XCTAssertEqual(listed.first?.phase, .offline)
    }

    /// A status a bot sets reaches its owner's devices with the bot, and they hear that it changed.
    func testBotsCarryTheStatusTheySet() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        XCTAssertNil(bot.status)
        f.hub.bots.checkForChanges()
        let events = try await f.device.subscribe()
        // A round trip, so the Hub has the subscription before anything changes.
        _ = try await f.device.request(.bots)
        _ = try f.hub.repository.setAgentStatus("Reviewing PR 42", agentID: bot.id)
        f.hub.bots.checkForChanges()
        for try await event in events { if case .botsChanged = event { break } }
        guard case .bots(let listed) = try await f.device.request(.bots) else { return XCTFail("no bots") }
        XCTAssertEqual(listed.first?.status, "Reviewing PR 42")
    }

    func testOtherUsersCannotReachABot() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        let grace = try f.hub.access.addUser(named: "Grace")
        let other = HubPairing(directory: FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-other-\(UUID())"),
                               deviceName: "Other")
        await other.join(f.link.invite(grace).url().absoluteString)
        let listed = try await other.request(.bots)
        XCTAssertEqual(listed, .bots([]))
        do {
            _ = try await other.request(.send(LinkOutgoingMessage(conversationID: bot.conversationID, id: UUID(), body: "Hi", attachmentIDs: [])))
            XCTFail("Reached another user's bot")
        } catch {}
        do {
            _ = try await other.request(.deleteBot(id: bot.id))
            XCTFail("Deleted another user's bot")
        } catch {}
    }

    func testABotStopsWhenThePlanNoLongerLendsItsHarness() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        f.hub.access.move(f.ada, to: f.hub.access.plans[0])
        do {
            _ = try await f.device.request(.send(LinkOutgoingMessage(conversationID: bot.conversationID, id: UUID(), body: "Hello", attachmentIDs: [])))
            XCTFail("Sent through a harness the plan no longer lends")
        } catch {
            XCTAssertEqual((error as? LinkError)?.message, "Your plan no longer lends Claude Code.")
        }
    }

    func testDeletingABotOrItsUserRemovesItFromTheHub() async throws {
        let f = try await fixture()
        let first = try await createBot(f)
        let deleted = try await f.device.request(.deleteBot(id: first.id))
        XCTAssertEqual(deleted, .done)
        XCTAssertTrue(try f.hub.repository.loadAgents().isEmpty)

        let second = try await createBot(f)
        f.hub.remove(f.ada)
        XCTAssertTrue(try f.hub.repository.loadAgents().isEmpty)
        XCTAssertNil(f.hub.access.owner(ofBot: second.id))
    }

    func testAnArchivedBotIsKeptButTakesNoMessagesUntilUnarchived() async throws {
        let f = try await fixture()
        let alfred = try await createBot(f)
        guard case .bot(let jeeves) = try await f.device.request(.createBot(LinkBotDraft(name: "Jeeves", provider: "claude-code"))) else {
            return XCTFail("no bot")
        }
        let group = try await createGroup(f, of: [alfred, jeeves])
        let answer = try await f.device.request(.archive(LinkArchiveChange(id: alfred.id, archived: true)))
        XCTAssertEqual(answer, .done)
        guard case .bots(let bots) = try await f.device.request(.bots) else { return XCTFail("no bots") }
        XCTAssertNotNil(bots.first { $0.id == alfred.id }?.archivedAt)
        XCTAssertNil(bots.first { $0.id == jeeves.id }?.archivedAt)
        XCTAssertEqual(f.hub.runtime.archivedAgentIDs, [alfred.id])
        do {
            _ = try await f.device.request(.send(LinkOutgoingMessage(conversationID: alfred.conversationID, id: UUID(), body: "Hello")))
            XCTFail("Reached an archived bot")
        } catch {
            XCTAssertEqual((error as? LinkError)?.message, "Alfred is archived.")
        }
        // The group still has Jeeves.
        _ = try await f.device.request(.send(LinkOutgoingMessage(conversationID: group.id, id: UUID(), body: "Dinner at eight.")))

        _ = try await f.device.request(.archive(LinkArchiveChange(id: alfred.id, archived: false)))
        XCTAssertTrue(f.hub.runtime.archivedAgentIDs.isEmpty)
        _ = try await f.device.request(.send(LinkOutgoingMessage(conversationID: alfred.conversationID, id: UUID(), body: "Hello")))
    }

    func testAnArchivedGroupKeepsItsMessagesAndBots() async throws {
        let f = try await fixture()
        let alfred = try await createBot(f)
        let group = try await createGroup(f, of: [alfred])
        _ = try await f.device.request(.send(LinkOutgoingMessage(conversationID: group.id, id: UUID(), body: "Dinner at eight.")))
        _ = try await f.device.request(.archive(LinkArchiveChange(id: group.id, archived: true)))
        guard case .groups(let groups) = try await f.device.request(.groups) else { return XCTFail("no groups") }
        XCTAssertNotNil(groups.first?.archivedAt)
        XCTAssertTrue(f.hub.runtime.archivedAgentIDs.isEmpty, "Its bots keep running")
        do {
            _ = try await f.device.request(.send(LinkOutgoingMessage(conversationID: group.id, id: UUID(), body: "Anyone?")))
            XCTFail("Reached an archived group")
        } catch {
            XCTAssertEqual((error as? LinkError)?.message, "This group is archived.")
        }
        guard case .messages(let page) = try await f.device.request(.messages(conversationID: group.id, after: 0)) else {
            return XCTFail("no messages")
        }
        XCTAssertEqual(page.messages.map(\.body), ["Dinner at eight."])

        _ = try await f.device.request(.archive(LinkArchiveChange(id: group.id, archived: false)))
        guard case .groups(let restored) = try await f.device.request(.groups) else { return XCTFail("no groups") }
        XCTAssertNil(restored.first?.archivedAt)
    }

    func testOnlyTheOwnerArchives() async throws {
        let f = try await fixture()
        let alfred = try await createBot(f)
        let group = try await createGroup(f, of: [alfred])
        let grace = try f.hub.access.addUser(named: "Grace")
        let other = HubPairing(directory: FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-other-\(UUID())"),
                               deviceName: "Other")
        await other.join(f.link.invite(grace).url().absoluteString)
        for id in [alfred.id, group.id] {
            do {
                _ = try await other.request(.archive(LinkArchiveChange(id: id, archived: true)))
                XCTFail("Archived another user's bot or group")
            } catch {}
        }
        XCTAssertNil(try f.hub.repository.loadAgents().first?.archivedAt)
        XCTAssertNil(try f.hub.repository.loadConversations().first { $0.id == group.id }?.archivedAt)
    }

    /// Settings on the Hub lists every group with its owner and archives for whoever owns it.
    func testTheHubsKeeperArchivesForTheOwner() async throws {
        let f = try await fixture()
        let alfred = try await createBot(f)
        let group = try await createGroup(f, of: [alfred])
        XCTAssertEqual(try f.hub.bots.everyGroup().map(\.conversation.id), [group.id])
        XCTAssertEqual(try f.hub.bots.everyGroup().first?.owner, f.ada.id)

        try f.hub.bots.setArchived(true, id: alfred.id)
        try f.hub.bots.setArchived(true, id: group.id)
        guard case .bots(let bots) = try await f.device.request(.bots) else { return XCTFail("no bots") }
        XCTAssertNotNil(bots.first?.archivedAt)
        guard case .groups(let groups) = try await f.device.request(.groups) else { return XCTFail("no groups") }
        XCTAssertNotNil(groups.first?.archivedAt)

        try f.hub.bots.setArchived(false, id: alfred.id)
        try f.hub.bots.setArchived(false, id: group.id)
        XCTAssertNil(try f.hub.repository.loadAgents().first?.archivedAt)
        XCTAssertThrowsError(try f.hub.bots.setArchived(true, id: UUID()))
    }

    private func createGroup(_ f: Fixture, of bots: [LinkBot]) async throws -> LinkGroup {
        guard case .group(let group) = try await f.device.request(.createGroup(LinkGroupDraft(
            name: "House", publicDescription: "Runs the house", botIDs: bots.map(\.id)))) else {
            throw XCTSkip("unexpected answer")
        }
        return group
    }

    func testAGroupOfTheUsersBotsIsKeptOnTheHub() async throws {
        let f = try await fixture()
        let alfred = try await createBot(f)
        let jeeves = try await createBot(f)
        let group = try await createGroup(f, of: [alfred, jeeves])
        XCTAssertEqual(Set(group.draft.botIDs), [alfred.id, jeeves.id])
        let listed = try await f.device.request(.groups)
        XCTAssertEqual(listed, .groups([group]))
        let kept = try XCTUnwrap(f.hub.repository.loadConversations().first { $0.id == group.id })
        XCTAssertEqual(kept.kind, .group)
        XCTAssertEqual(kept.displayName, "House")

        _ = try await f.device.request(.send(LinkOutgoingMessage(conversationID: group.id, id: UUID(), body: "Dinner at eight.")))
        _ = try f.hub.repository.sendAgentMessage(agentID: jeeves.id, conversationID: group.id, body: "Very good.")
        guard case .messages(let page) = try await f.device.request(.messages(conversationID: group.id, after: 0)) else {
            return XCTFail("no messages")
        }
        XCTAssertEqual(page.messages.map(\.body), ["Dinner at eight.", "Very good."])
        XCTAssertEqual(page.messages.last?.author, .bot(jeeves.id))

        guard case .group(let renamed) = try await f.device.request(.updateGroup(id: group.id, LinkGroupDraft(
            name: "Staff", publicDescription: "", botIDs: [alfred.id]))) else { return XCTFail("not renamed") }
        XCTAssertEqual(renamed.draft.name, "Staff")
        XCTAssertEqual(renamed.draft.botIDs, [alfred.id])

        let deleted = try await f.device.request(.deleteGroup(id: group.id))
        XCTAssertEqual(deleted, .done)
        XCTAssertFalse(try f.hub.repository.loadConversations().contains { $0.id == group.id })
        XCTAssertEqual(try f.hub.repository.loadAgents().count, 2, "deleting the group deleted its bots")
    }

    func testAGroupTakesOnlyItsUsersOwnBots() async throws {
        let f = try await fixture()
        let alfred = try await createBot(f)
        let grace = try f.hub.access.addUser(named: "Grace")
        f.hub.access.move(grace, to: f.hub.access.plans.first { $0.name == "Family" }!)
        let other = HubPairing(directory: FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-other-\(UUID())"),
                               deviceName: "Other")
        await other.join(f.link.invite(grace).url().absoluteString)
        guard case .bot(let hers) = try await other.request(.createBot(LinkBotDraft(name: "Marvin", provider: "claude-code"))) else {
            return XCTFail("no bot")
        }
        do {
            _ = try await createGroup(f, of: [alfred, hers])
            XCTFail("Made a group with another user's bot")
        } catch {}

        let group = try await createGroup(f, of: [alfred])
        let listed = try await other.request(.groups)
        XCTAssertEqual(listed, .groups([]))
        do {
            _ = try await other.request(.send(LinkOutgoingMessage(conversationID: group.id, id: UUID(), body: "Hi")))
            XCTFail("Reached another user's group")
        } catch {}
    }

    /// A group whose last bot is deleted goes with it, rather than staying on the Hub with no one to show it.
    func testAGroupGoesWithItsLastBot() async throws {
        let f = try await fixture()
        let alfred = try await createBot(f)
        let group = try await createGroup(f, of: [alfred])
        _ = try await f.device.request(.deleteBot(id: alfred.id))
        XCTAssertFalse(try f.hub.repository.loadConversations().contains { $0.id == group.id })
    }

    func testFilesTravelToAndFromABotInPieces() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        let bytes = Data("%PDF-1.4\n".utf8) + Data((0..<1_300_000).map { UInt8($0 % 251) })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hub-upload-\(UUID()).pdf")
        try bytes.write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let attachment = LinkAttachment(id: UUID(), filename: "Report.pdf", mediaType: "application/pdf", byteCount: bytes.count)

        try await f.device.upload(file, as: attachment, to: bot.conversationID)
        _ = try await f.device.request(.send(LinkOutgoingMessage(conversationID: bot.conversationID, id: UUID(), body: "What is in this file?",
                                             attachmentIDs: [attachment.id])))
        let stored = try XCTUnwrap(f.hub.repository.loadAttachments(conversationID: bot.conversationID).first)
        XCTAssertEqual(stored.id, attachment.id)
        XCTAssertEqual(stored.originalFilename, "Report.pdf")
        XCTAssertEqual(try Data(contentsOf: f.hub.repository.attachmentFileURL(stored)), bytes)
        XCTAssertEqual(try f.hub.repository.loadMessages(conversationID: bot.conversationID).first?.attachmentIDs, [attachment.id])

        guard case .messages(let page) = try await f.device.request(.messages(conversationID: bot.conversationID, after: 0)) else {
            return XCTFail("no messages")
        }
        XCTAssertEqual(page.messages.first?.attachments, [attachment])
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("hub-download-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: copy) }
        try await f.device.download(attachment, from: bot.conversationID, to: copy)
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
    }

    func testAFileLargerThanTheHubTakesIsRefusedAtItsFirstPiece() async throws {
        let f = try await fixture()
        XCTAssertEqual(f.link.uploadLimit, 100_000_000)
        let bot = try await createBot(f)
        f.link.uploadLimit = 1_000_000
        let large = LinkAttachment(id: UUID(), filename: "Film.mov", mediaType: "video/quicktime", byteCount: 1_000_001)
        do {
            _ = try await f.device.request(.upload(conversationID: bot.conversationID, attachment: large, offset: 0, data: Data(count: 10)))
            XCTFail("A file over the limit was taken")
        } catch {
            XCTAssertEqual((error as? LinkError)?.message, "Mac mini takes files up to 1 MB.")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hub-upload-\(UUID()).txt")
        try Data(count: 1_000_000).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let fits = LinkAttachment(id: UUID(), filename: "Note.txt", mediaType: "text/plain", byteCount: 1_000_000)
        try await f.device.upload(file, as: fits, to: bot.conversationID)
        XCTAssertEqual(try f.hub.repository.loadAttachments(conversationID: bot.conversationID).map(\.id), [fits.id])
    }

    func testPiecesOfFilesNoLongerArrivingAreCleared() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        let manager = FileManager.default
        func part(untouchedFor age: TimeInterval) throws -> URL {
            try manager.createDirectory(at: f.uploads, withIntermediateDirectories: true)
            let url = f.uploads.appendingPathComponent("\(UUID().uuidString).part")
            try Data(count: 10).write(to: url)
            try manager.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
            return url
        }
        let abandoned = try part(untouchedFor: 2 * 3600), arriving = try part(untouchedFor: 60)
        let file = manager.temporaryDirectory.appendingPathComponent("hub-upload-\(UUID()).txt")
        try Data("hello".utf8).write(to: file)
        addTeardownBlock { try? manager.removeItem(at: file) }
        try await f.device.upload(file, as: LinkAttachment(id: UUID(), filename: "Note.txt", mediaType: "text/plain", byteCount: 5),
                                  to: bot.conversationID)
        XCTAssertFalse(manager.fileExists(atPath: abandoned.path))
        XCTAssertTrue(manager.fileExists(atPath: arriving.path))

        // And when the Hub opens again, before anything is sent.
        let left = try part(untouchedFor: 2 * 3600)
        _ = Hub(root: f.uploads.deletingLastPathComponent(), messenger: nil)
        XCTAssertFalse(manager.fileExists(atPath: left.path))
        XCTAssertTrue(manager.fileExists(atPath: arriving.path))
    }

    func testTheUploadLimitIsKeptAcrossLaunches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-limit-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(root: root.appendingPathComponent("Hub"), messenger: nil)
        func link() -> HubLinkService {
            HubLinkService(hubName: "Mac mini", directory: root.appendingPathComponent("Link"), access: hub.access,
                           profiles: hub.harnessProfiles)
        }
        link().uploadLimit = 5_000_000
        XCTAssertEqual(link().uploadLimit, 5_000_000)
    }

    func testPicturesArriveWithTheirSize() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hub-picture-\(UUID()).png")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage())).representation(using: .png, properties: [:]))
        try png.write(to: file)
        let attachment = LinkAttachment(id: UUID(), filename: "Photo.png", mediaType: "image/png", byteCount: png.count)
        try await f.device.upload(file, as: attachment, to: bot.conversationID)
        _ = try await f.device.request(.send(LinkOutgoingMessage(conversationID: bot.conversationID, id: UUID(), body: "Look",
                                             attachmentIDs: [attachment.id])))
        guard case .messages(let page) = try await f.device.request(.messagePage(LinkMessagePage(conversationID: bot.conversationID,
                                                                                                 before: nil, limit: 50))) else {
            return XCTFail("no messages")
        }
        XCTAssertEqual(page.messages.first?.attachments.first?.pixelSize, LinkPixelSize(width: 40, height: 30))
    }

    func testVoiceMessagesKeepTheirTranscript() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).caf")
        try Data([1, 2, 3]).write(to: audio)
        let voice = LinkVoice(transcript: "Book a table", duration: 2, waveform: [0.2, 0.8], localeIdentifier: "en_GB")
        let attachment = LinkAttachment(id: UUID(), filename: "Voice message.caf", mediaType: "audio/x-caf", byteCount: 3, voice: voice)
        try await f.device.upload(audio, as: attachment, to: bot.conversationID)
        guard case .message(let sent) = try await f.device.request(.send(LinkOutgoingMessage(
            conversationID: bot.conversationID, id: UUID(), body: "Voice message", attachmentIDs: [attachment.id]))) else {
            return XCTFail("no message")
        }
        XCTAssertEqual(sent.attachments.first?.voice, voice)
        // The bot reads the transcript from the stored file.
        let stored = try XCTUnwrap(f.hub.repository.loadAttachments(conversationID: bot.conversationID).first)
        XCTAssertEqual(stored.voice?.transcript, "Book a table")
    }

    func testMessagesCannotPointAtFilesThatNeverArrived() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        do {
            _ = try await f.device.request(.send(LinkOutgoingMessage(conversationID: bot.conversationID, id: UUID(), body: "See file",
                                                 attachmentIDs: [UUID()])))
            XCTFail("Sent a message pointing at a missing file")
        } catch {
            XCTAssertEqual((error as? LinkError)?.message, "An attachment has not reached the Hub yet.")
        }
    }

    // MARK: Sharing

    /// Someone else on the Hub, with a device of their own, on a plan that lends nothing.
    private func person(_ name: String, _ f: Fixture) async throws -> (user: HubUser, device: HubPairing) {
        let user = try f.hub.access.addUser(named: name)
        let device = HubPairing(directory: FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-\(name)-\(UUID())"),
                                deviceName: name)
        addTeardownBlock { try? FileManager.default.removeItem(at: device.directory) }
        await device.join(f.link.invite(user).url().absoluteString)
        XCTAssertNil(device.error)
        return (user, device)
    }

    private func share(_ bot: LinkBot, with people: [HubUser], _ f: Fixture) async throws -> LinkBot {
        guard case .bot(let shared) = try await f.device.request(.shareBot(id: bot.id, people: people.map(\.id))) else {
            throw XCTSkip("unexpected answer")
        }
        return shared
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

    private func bots(of device: HubPairing) async throws -> [LinkBot] {
        guard case .bots(let bots) = try await device.request(.bots) else { throw XCTSkip("unexpected answer") }
        return bots
    }

    /// Anyone on the Hub can be picked to share with; nobody picks themselves.
    func testOwnersSeeWhoElseIsOnTheHub() async throws {
        let f = try await fixture()
        let grace = try await person("Grace", f)
        let listed = try await f.device.request(.people)
        XCTAssertEqual(listed, .people([LinkPerson(id: grace.user.id, name: "Grace")]))
        guard case .status(let status) = try await f.device.request(.status) else { return XCTFail("no status") }
        XCTAssertTrue(status.canShareBots)
    }

    /// Someone's picture reaches everyone who can share with them, and their own other devices.
    func testPeopleSeeThePictureSomeoneChose() async throws {
        let f = try await fixture()
        let grace = try await person("Grace", f)
        func adaAsGraceSees() async throws -> LinkPerson? {
            try await grace.device.people().first { $0.id == f.ada.id }
        }
        var ada = try await adaAsGraceSees()
        XCTAssertNotNil(ada)
        XCTAssertNil(ada?.avatar)

        let photo = try smallJPEG()
        try await f.device.setAvatar(LinkAvatar(colour: 2, image: photo))
        XCTAssertEqual(f.device.avatar?.image, photo)
        ada = try await adaAsGraceSees()
        XCTAssertEqual(ada?.avatar?.image, photo)
        XCTAssertEqual(ada?.avatar?.colour, 2)

        let phone = HubPairing(directory: FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-phone-\(UUID())"),
                               deviceName: "Phone")
        addTeardownBlock { try? FileManager.default.removeItem(at: phone.directory) }
        await phone.join(f.link.invite(f.ada).url().absoluteString)
        await phone.refresh()
        XCTAssertEqual(phone.avatar?.image, photo)

        // Changing the colour sends the photo's digest alone, and keeps the photo.
        var edited = try XCTUnwrap(f.device.avatar)
        edited.colour = 4
        XCTAssertNil(edited.leavingOutKnownImage.image)
        try await f.device.setAvatar(edited)
        ada = try await adaAsGraceSees()
        XCTAssertEqual(ada?.avatar, LinkAvatar(colour: 4, image: photo, imageDigest: LinkPicture.digest(photo)))

        try await f.device.setAvatar(LinkAvatar(symbol: "leaf.fill", colour: 1))
        ada = try await adaAsGraceSees()
        XCTAssertEqual(ada?.avatar, LinkAvatar(symbol: "leaf.fill", colour: 1))
        try await f.device.setAvatar(nil)
        XCTAssertNil(f.device.avatar)
        ada = try await adaAsGraceSees()
        XCTAssertNil(ada?.avatar)
    }

    /// Only a picture fit to show anyone is kept.
    func testAPictureMustBeAnImageOfAModestSize() async throws {
        let f = try await fixture()
        do {
            try await f.device.setAvatar(LinkAvatar(image: Data("not a picture".utf8)))
            XCTFail("kept something that is not a picture")
        } catch {}
        do {
            try await f.device.setAvatar(LinkAvatar(image: try smallJPEG() + Data(count: HubAccess.maxPictureBytes)))
            XCTFail("kept a picture too large")
        } catch {}
        do {
            try await f.device.setAvatar(LinkAvatar(imageDigest: LinkPicture.digest(Data([1]))))
            XCTFail("kept a picture the Hub never had")
        } catch {}
        XCTAssertNil(f.device.avatar)
    }

    /// Activity records who shared a bot with whom and who stopped, and a refused attempt.
    func testSharingIsRecordedInActivity() async throws {
        let f = try await fixture()
        f.hub.access.log = HubActivityLog(url: f.uploads.deletingLastPathComponent().appendingPathComponent("activity.jsonl"))
        let bot = try await createBot(f)
        let grace = try await person("Grace", f)
        let bea = try await person("Bea", f)
        _ = try await share(bot, with: [grace.user, bea.user], f)
        _ = try await share(bot, with: [bea.user], f)
        _ = try? await grace.device.request(.shareBot(id: bot.id, people: [grace.user.id]))
        let entries = try XCTUnwrap(f.hub.access.log?.entries).filter { $0.what.contains("Alfred") }
        XCTAssertEqual(entries.map(\.what), ["Shared Alfred with Bea", "Shared Alfred with Grace", "Stopped sharing Alfred with Grace",
                                             "Tried to change whom Alfred is shared with"])
        XCTAssertEqual(entries.map(\.who), ["Ada on Mac", "Ada on Mac", "Ada on Mac", "Grace on Grace"])
        guard entries.count == 4 else { return }
        XCTAssertNil(entries[0].refusal)
        XCTAssertNotNil(entries[3].refusal)
        XCTAssertTrue(entries[1].users.contains(grace.user.id))
    }

    /// Each person a bot is shared with talks with the same bot in a conversation of their own,
    /// on the owner's plan, whatever their own plan lends.
    func testABotSharedWithPeopleTalksWithEachInTheirOwnConversation() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        let grace = try await person("Grace", f)
        let bea = try await person("Bea", f)
        let shared = try await share(bot, with: [grace.user, bea.user], f)
        XCTAssertEqual(Set(shared.sharedWith), [grace.user.id, bea.user.id])
        let adas = try await bots(of: f.device)
        XCTAssertEqual(adas.first?.sharedWith.count, 2)

        guard let graces = try await bots(of: grace.device).first else { return XCTFail("not shared") }
        guard let beas = try await bots(of: bea.device).first else { return XCTFail("not shared") }
        XCTAssertEqual(graces.id, bot.id)
        XCTAssertEqual(graces.owner, "Ada")
        XCTAssertEqual(graces.draft.name, "Alfred")
        XCTAssertEqual(Set([bot.conversationID, graces.conversationID, beas.conversationID]).count, 3)

        _ = try await grace.device.request(.send(LinkOutgoingMessage(conversationID: graces.conversationID, id: UUID(), body: "Hello")))
        _ = try f.hub.repository.sendAgentMessage(agentID: bot.id, conversationID: graces.conversationID, body: "Good evening, Grace.")
        guard case .messages(let page) = try await grace.device.request(.messages(conversationID: graces.conversationID, after: 0)) else {
            return XCTFail("no messages")
        }
        XCTAssertEqual(page.messages.map(\.body), ["Hello", "Good evening, Grace."])
        XCTAssertEqual(page.messages.first?.author, .you)
        for (device, conversation) in [(f.device, graces.conversationID), (bea.device, graces.conversationID),
                                       (grace.device, bot.conversationID), (grace.device, beas.conversationID)] {
            do {
                _ = try await device.request(.messages(conversationID: conversation, after: 0))
                XCTFail("Read someone else's conversation with the bot")
            } catch {}
        }
    }

    /// The bot knows who it talks with, by name, and tells its owner apart from people it is shared with.
    func testTheBotKnowsWhoItTalksWith() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        let grace = try await person("Grace", f)
        _ = try await share(bot, with: [grace.user], f)
        guard let graces = try await bots(of: grace.device).first else { return XCTFail("not shared") }
        _ = try await f.device.request(.send(LinkOutgoingMessage(conversationID: bot.conversationID, id: UUID(), body: "From Ada")))
        _ = try await grace.device.request(.send(LinkOutgoingMessage(conversationID: graces.conversationID, id: UUID(), body: "From Grace")))
        let senders = try f.hub.repository.latestMessages(for: bot.id, consuming: false)
            .map { "\($0.message.body): \($0.sender.handle.rawValue) \($0.sender.displayName)" }
        XCTAssertEqual(Set(senders), ["From Ada: user Ada", "From Grace: guest Grace"])

        // A new name reaches the bot.
        try f.hub.access.rename(grace.user, to: "Grace Hopper")
        let renamed = try f.hub.repository.latestMessages(for: bot.id, consuming: false).first { $0.message.body == "From Grace" }
        XCTAssertEqual(renamed?.sender.displayName, "Grace Hopper")
    }

    /// The bot's AGENTS.md names its owner, before any message arrives, and follows a new name.
    func testTheBotKnowsItsOwnerFromTheStart() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        guard let agent = try f.hub.repository.loadAgents().first(where: { $0.id == bot.id }) else { return XCTFail("no bot") }
        let instructions = f.hub.repository.directory(for: agent).appendingPathComponent("AGENTS.md")
        XCTAssertTrue(try String(contentsOf: instructions, encoding: .utf8).contains("Your owner is Ada."))

        try f.hub.access.rename(f.ada, to: "Ada Lovelace")
        XCTAssertTrue(try String(contentsOf: instructions, encoding: .utf8).contains("Your owner is Ada Lovelace."))
    }

    /// People a bot is shared with see whether it is working, like its owner, and hear when that changes.
    func testPeopleABotIsSharedWithSeeWhetherItIsWorking() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        let grace = try await person("Grace", f)
        _ = try await share(bot, with: [grace.user], f)
        guard let graces = try await bots(of: grace.device).first else { return XCTFail("not shared") }
        // The runtime is not started here, so the bot is offline.
        XCTAssertEqual(graces.phase, .offline)
        f.hub.bots.checkForChanges()
        let events = try await grace.device.subscribe()
        _ = try await grace.device.request(.bots)
        // Without starting anything: the runtime finds no harness for it, so it fails.
        var harnessless = try XCTUnwrap(f.hub.repository.loadAgents().first)
        harnessless.harnessIdentifier = nil
        f.hub.runtime.refresh(agents: [harnessless])
        f.hub.bots.checkForChanges()
        let id = bot.id
        try await expect("that the bot failed", in: events) { if case .botPhase(id, .failed) = $0 { true } else { false } }
    }

    /// People a bot is shared with only talk with it: they never see how it is made or the status it sets.
    func testPeopleABotIsSharedWithSeeNothingOfItsWorkings() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        let grace = try await person("Grace", f)
        _ = try await share(bot, with: [grace.user], f)
        _ = try f.hub.repository.setAgentStatus("Reading Ada's mail", agentID: bot.id)
        guard let graces = try await bots(of: grace.device).first else { return XCTFail("not shared") }
        XCTAssertNil(graces.status)
        XCTAssertEqual(graces.draft.backstory, "")
        XCTAssertEqual(graces.draft.provider, "")
        XCTAssertNil(graces.draft.model)
        XCTAssertNil(graces.draft.profile)
        XCTAssertEqual(graces.sharedWith, [])
    }

    /// Only the owner edits, shares, kicks or deletes a bot.
    func testOnlyTheOwnerManagesASharedBot() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        let grace = try await person("Grace", f)
        let bea = try await person("Bea", f)
        _ = try await share(bot, with: [grace.user], f)
        guard case .group(let group) = try await f.device.request(.createGroup(LinkGroupDraft(name: "House", botIDs: [bot.id]))) else {
            return XCTFail("no group")
        }
        let refused: [LinkRequest] = [
            .shareBot(id: bot.id, people: [grace.user.id, bea.user.id]), .shareBot(id: bot.id, people: []),
            .updateBot(id: bot.id, LinkBotDraft(name: "Mine", provider: "claude-code")), .deleteBot(id: bot.id),
            .kick(botID: bot.id), .confirmKick(botID: bot.id, confirmationID: UUID()), .newSession(botID: bot.id),
            .archive(LinkArchiveChange(id: bot.id, archived: true)), .assignConnections(botID: bot.id, connectionIDs: []),
            .createGroup(LinkGroupDraft(name: "Mine", botIDs: [bot.id])),
            .updateGroup(id: group.id, LinkGroupDraft(name: "Mine", botIDs: [bot.id])), .deleteGroup(id: group.id),
        ]
        for request in refused {
            do {
                _ = try await grace.device.request(request)
                XCTFail("Someone the bot is shared with managed it: \(request)")
            } catch {}
        }
        let adas = try await bots(of: f.device)
        XCTAssertEqual(adas.first?.sharedWith, [grace.user.id])
        let beasBots = try await bots(of: bea.device)
        XCTAssertEqual(beasBots, [])
    }

    /// The owner stops sharing with someone, who loses the bot and their conversation with it.
    func testTheOwnerStopsSharingWithSomeone() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        let grace = try await person("Grace", f)
        let bea = try await person("Bea", f)
        _ = try await share(bot, with: [grace.user, bea.user], f)
        guard let graces = try await bots(of: grace.device).first else { return XCTFail("not shared") }
        let events = try await grace.device.subscribe()
        _ = try await grace.device.request(.bots)
        let shared = try await share(bot, with: [bea.user], f)
        XCTAssertEqual(shared.sharedWith, [bea.user.id])
        try await expect("that the bot is gone", in: events) { if case .botsChanged = $0 { true } else { false } }
        let gracesBots = try await bots(of: grace.device)
        XCTAssertEqual(gracesBots, [])
        let beasBots = try await bots(of: bea.device)
        XCTAssertEqual(beasBots.count, 1)
        do {
            _ = try await grace.device.request(.send(LinkOutgoingMessage(conversationID: graces.conversationID, id: UUID(), body: "Hi")))
            XCTFail("Talked with a bot no longer shared")
        } catch {}
        XCTAssertFalse(try f.hub.repository.loadConversations().contains { $0.id == graces.conversationID })
    }

    /// People a bot is shared with hear when its owner renames, archives or brings it back.
    func testPeopleABotIsSharedWithHearOfItsChanges() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        let grace = try await person("Grace", f)
        _ = try await share(bot, with: [grace.user], f)
        guard let before = try await bots(of: grace.device).first else { return XCTFail("not shared") }
        for change in [LinkRequest.updateBot(id: bot.id, LinkBotDraft(name: "Jeeves", provider: "claude-code")),
                       .archive(LinkArchiveChange(id: bot.id, archived: true))] {
            let events = try await grace.device.subscribe()
            _ = try await grace.device.request(.bots)
            _ = try await f.device.request(change)
            try await expect("of \(change)", in: events) { if case .botsChanged = $0 { true } else { false } }
        }
        // Archived, it is its owner's alone until brought back, with the same conversation.
        let whileArchived = try await bots(of: grace.device)
        XCTAssertEqual(whileArchived, [])
        let events = try await grace.device.subscribe()
        _ = try await grace.device.request(.bots)
        _ = try await f.device.request(.archive(LinkArchiveChange(id: bot.id, archived: false)))
        try await expect("that it is back", in: events) { if case .botsChanged = $0 { true } else { false } }
        guard let graces = try await bots(of: grace.device).first else { return XCTFail("not shared") }
        XCTAssertEqual(graces.draft.name, "Jeeves")
        XCTAssertNil(graces.archivedAt)
        XCTAssertEqual(graces.conversationID, before.conversationID)
    }

    /// A bot's replies reach the devices of whoever it replied to.
    func testRepliesInASharedConversationReachThatPerson() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        let grace = try await person("Grace", f)
        _ = try await share(bot, with: [grace.user], f)
        guard let graces = try await bots(of: grace.device).first else { return XCTFail("not shared") }
        let events = try await grace.device.subscribe()
        _ = try await grace.device.request(.bots)
        _ = try f.hub.repository.sendAgentMessage(agentID: bot.id, conversationID: graces.conversationID, body: "Tea?")
        f.hub.bots.checkForChanges()
        let conversation = graces.conversationID
        try await expect("the reply", in: events) { if case .conversationChanged(conversation, 1) = $0 { true } else { false } }
    }

    /// While its owner has it archived, a shared bot's conversations are closed to everyone else,
    /// even asked for by their IDs, and open again once it is back.
    func testAnArchivedSharedBotIsClosedToEveryoneButItsOwner() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        let grace = try await person("Grace", f)
        _ = try await share(bot, with: [grace.user], f)
        guard let graces = try await bots(of: grace.device).first else { return XCTFail("not shared") }
        _ = try await grace.device.request(.send(LinkOutgoingMessage(conversationID: graces.conversationID, id: UUID(), body: "Hello")))
        _ = try await f.device.request(.archive(LinkArchiveChange(id: bot.id, archived: true)))
        for request in [LinkRequest.messages(conversationID: graces.conversationID, after: 0),
                        .messagePage(LinkMessagePage(conversationID: graces.conversationID, before: nil, limit: 50))] {
            do {
                _ = try await grace.device.request(request)
                XCTFail("Read an archived bot's conversation: \(request)")
            } catch {}
        }
        guard case .messages = try await f.device.request(.messages(conversationID: bot.conversationID, after: 0)) else {
            return XCTFail("The owner could not read their own")
        }
        _ = try await f.device.request(.archive(LinkArchiveChange(id: bot.id, archived: false)))
        guard case .messages(let page) = try await grace.device.request(.messages(conversationID: graces.conversationID, after: 0)) else {
            return XCTFail("not open again")
        }
        XCTAssertEqual(page.messages.map(\.body), ["Hello"])
    }

    /// A notification of unread replies goes once the person can no longer open the conversation.
    func testUnsharingOrArchivingTakesBackNotifications() async throws {
        let pushes = RecordedPushes()
        let f = try await fixture(pushes: pushes)
        let bot = try await createBot(f)
        let grace = try await person("Grace", f)
        _ = try await grace.device.request(.pushTopic(LinkPushTopic(topic: "grace-topic")))
        for cutOff in ["archive", "unshare"] {
            _ = try await share(bot, with: [grace.user], f)
            guard let graces = try await bots(of: grace.device).first else { return XCTFail("not shared") }
            f.hub.bots.checkForChanges()
            _ = try f.hub.repository.sendAgentMessage(agentID: bot.id, conversationID: graces.conversationID, body: "Tea?")
            f.hub.bots.checkForChanges()
            for _ in 0..<50 where await pushes.unread("grace-topic", graces.conversationID) != 1 { try await Task.sleep(for: .milliseconds(100)) }
            let shown = await pushes.unread("grace-topic", graces.conversationID)
            XCTAssertEqual(shown, 1)
            if cutOff == "archive" {
                _ = try await f.device.request(.archive(LinkArchiveChange(id: bot.id, archived: true)))
            } else {
                _ = try await share(bot, with: [], f)
            }
            for _ in 0..<50 where await pushes.unread("grace-topic", graces.conversationID) != nil { try await Task.sleep(for: .milliseconds(100)) }
            let afterwards = await pushes.unread("grace-topic", graces.conversationID)
            XCTAssertNil(afterwards, "The notification stayed after \(cutOff)")
            if cutOff == "archive" {
                _ = try await f.device.request(.archive(LinkArchiveChange(id: bot.id, archived: false)))
                _ = try await share(bot, with: [], f)
            }
        }
    }

    /// Someone a bot is shared with is refused once its owner's plan no longer lends its harness.
    func testASharedBotStopsWhenItsOwnersPlanNoLongerLendsItsHarness() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        let grace = try await person("Grace", f)
        _ = try await share(bot, with: [grace.user], f)
        guard let graces = try await bots(of: grace.device).first else { return XCTFail("not shared") }
        f.hub.access.move(f.ada, to: f.hub.access.plans[0])
        do {
            _ = try await grace.device.request(.send(LinkOutgoingMessage(conversationID: graces.conversationID, id: UUID(), body: "Hi")))
            XCTFail("Talked with a bot its owner's plan no longer lends")
        } catch {
            XCTAssertEqual((error as? LinkError)?.message, "Alfred cannot take messages right now.")
        }
    }

    /// The recent history a bot is woken with names whoever it is talking with.
    func testTheHistoryABotIsWokenWithNamesThePerson() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        let grace = try await person("Grace", f)
        _ = try await share(bot, with: [grace.user], f)
        guard let graces = try await bots(of: grace.device).first else { return XCTFail("not shared") }
        _ = try await grace.device.request(.send(LinkOutgoingMessage(conversationID: graces.conversationID, id: UUID(), body: "First")))
        _ = try f.hub.repository.latestMessages(for: bot.id)
        _ = try await grace.device.request(.send(LinkOutgoingMessage(conversationID: graces.conversationID, id: UUID(), body: "Second")))
        let context = try XCTUnwrap(MessageDeliveryContext.load(for: bot.id, repository: f.hub.repository))
        XCTAssertEqual(context.unreadMessages, ["Second"])
        XCTAssertEqual(context.recentMessages, ["Grace: First"])

        // Its owner by name too, as Messenger names them.
        _ = try f.hub.repository.latestMessages(for: bot.id)
        _ = try await f.device.request(.send(LinkOutgoingMessage(conversationID: bot.conversationID, id: UUID(), body: "Mine")))
        _ = try f.hub.repository.latestMessages(for: bot.id)
        _ = try await f.device.request(.send(LinkOutgoingMessage(conversationID: bot.conversationID, id: UUID(), body: "Again")))
        let owners = try XCTUnwrap(MessageDeliveryContext.load(for: bot.id, repository: f.hub.repository))
        XCTAssertEqual(owners.recentMessages, ["Ada: Mine"])
    }

    /// Deleting a shared bot, or removing someone from the Hub, leaves no conversation behind.
    func testSharedConversationsGoWithTheBotOrThePerson() async throws {
        let f = try await fixture()
        let first = try await createBot(f)
        let grace = try await person("Grace", f)
        _ = try await share(first, with: [grace.user], f)
        let events = try await grace.device.subscribe()
        _ = try await grace.device.request(.bots)
        _ = try await f.device.request(.deleteBot(id: first.id))
        try await expect("that the bot is gone", in: events) { if case .botsChanged = $0 { true } else { false } }
        XCTAssertTrue(try f.hub.repository.loadConversations().isEmpty)
        let gracesBots = try await bots(of: grace.device)
        XCTAssertEqual(gracesBots, [])

        let second = try await createBot(f)
        _ = try await share(second, with: [grace.user], f)
        f.hub.remove(grace.user)
        XCTAssertEqual(try f.hub.repository.loadConversations().map(\.id), [second.conversationID])
        let adas = try await bots(of: f.device)
        XCTAssertEqual(adas.first?.sharedWith, [])
    }
}
