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
}
