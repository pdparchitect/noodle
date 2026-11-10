import AppKit
import Foundation
import HubCore
import HubLink
import NoodleCore
import NoodleRuntime
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

    private func fixture(pushes: RecordedPushes? = nil, runtime: AgentRuntimeCoordinator? = nil) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-bots-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(root: root.appendingPathComponent("Hub"), messenger: nil, runtime: runtime)
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

    /// A device asks a bot it just made to say hello; the Hub wakes it with a note naming the conversation.
    func testADeviceAsksItsNewBotToIntroduceItself() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        let answer = try await f.device.request(.introduce(conversationID: bot.conversationID))
        XCTAssertEqual(answer, .done)
        var notes: [String] = []
        for _ in 0..<100 where notes.isEmpty {
            notes = try f.hub.repository.listWakes(agentID: bot.id).due.map(\.note)
            if notes.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertEqual(notes, [AgentWake.introductionNote(in: bot.conversationID)])
        do {
            _ = try await f.device.request(.introduce(conversationID: UUID()))
            XCTFail("a conversation that is not theirs")
        } catch {}
    }

    /// A device turns Image Generation on and off for its bot; the Hub grants the tool and says whether it has a model.
    func testADeviceGivesItsBotImageGenerationOnTheHub() async throws {
        let f = try await fixture()
        var draft = LinkBotDraft(name: "Alfred", provider: "claude-code")
        draft.imageGeneration = true
        guard case .bot(let bot) = try await f.device.request(.createBot(draft)) else { return XCTFail("unexpected answer") }
        XCTAssertTrue(bot.draft.imageGeneration)
        XCTAssertTrue(f.hub.imageGeneration.isAssigned(bot.id))
        XCTAssertEqual(try ImageGenerationSettings.load(root: f.hub.repository.rootURL).toolAssignments(readable: true), [bot.id: ["default"]])
        guard case .status(let status) = try await f.device.request(.status) else { return XCTFail("no status") }
        XCTAssertNil(status.imageModel, "No model is downloaded on this Hub")

        draft.imageGeneration = false
        guard case .bot(let updated) = try await f.device.request(.updateBot(id: bot.id, draft)) else { return XCTFail("unexpected answer") }
        XCTAssertFalse(updated.draft.imageGeneration)
        XCTAssertFalse(f.hub.imageGeneration.isAssigned(bot.id))

        draft.imageGeneration = true
        _ = try await f.device.request(.updateBot(id: bot.id, draft))
        _ = try await f.device.request(.deleteBot(id: bot.id))
        XCTAssertFalse(f.hub.imageGeneration.isAssigned(bot.id), "A deleted bot keeps no grant")
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
        do {
            _ = try await f.device.request(.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code", model: "opus")))
            XCTFail("Created a bot on a model the plan does not lend")
        } catch {
            XCTAssertEqual((error as? LinkError)?.message, "Your plan does not lend opus on Claude Code.")
        }
        guard case .bot(let bot) = try await f.device.request(.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code",
                                                                                     model: "sonnet"))) else {
            return XCTFail("unexpected answer")
        }
        f.hub.access.setModels(["haiku"], for: claude, in: f.hub.access.plans[1])
        _ = try await f.device.request(.send(LinkOutgoingMessage(conversationID: bot.conversationID, id: UUID(), body: "Hi", attachmentIDs: [])))
        guard case .messages(let page) = try await f.device.request(.messages(conversationID: bot.conversationID, after: 0)) else {
            return XCTFail("no messages")
        }
        XCTAssertEqual(page.messages.last?.body, "Hi")
        // Kept unread, for when the bot can run again.
        XCTAssertEqual(try f.hub.repository.latestMessages(for: bot.id, consuming: false).map(\.message.body), ["Hi"])
    }

    /// A bot the plan no longer lends cannot answer, so it shows as failed whatever its runtime does.
    func testABotThePlanNoLongerLendsShowsAsFailed() async throws {
        let f = try await fixture()
        f.hub.access.setModels(["sonnet", "haiku"], for: claude, in: f.hub.access.plans[1])
        guard case .bot(let alfred) = try await f.device.request(.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code", model: "sonnet"))) else {
            return XCTFail("no bot")
        }
        XCTAssertNotEqual(alfred.phase, .failed)
        f.hub.access.setModels(["haiku"], for: claude, in: f.hub.access.plans[1])
        guard case .bots(let bots) = try await f.device.request(.bots) else { return XCTFail("no bots") }
        XCTAssertEqual(bots.first { $0.id == alfred.id }?.phase, .failed)
    }

    /// Bots on a model their owner's plan stopped lending are listed with what it still lends, and
    /// moving one to a lent model lets it answer again.
    func testBotsOnAModelThePlanNoLongerLendsAreListedAndCanMove() async throws {
        let f = try await fixture()
        f.hub.access.setModels(["sonnet", "haiku", "opus"], for: claude, in: f.hub.access.plans[1])
        guard case .bot(let alfred) = try await f.device.request(.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code", model: "sonnet"))),
              case .bot = try await f.device.request(.createBot(LinkBotDraft(name: "Jeeves", provider: "claude-code", model: "haiku"))),
              case .bot = try await f.device.request(.createBot(LinkBotDraft(name: "Bunter", provider: "claude-code"))) else {
            return XCTFail("no bots")
        }
        XCTAssertEqual(f.hub.bots.unlentModels(), [])
        f.hub.access.setModels(["opus", "haiku"], for: claude, in: f.hub.access.plans[1])
        let unlent = f.hub.bots.unlentModels()
        XCTAssertEqual(unlent.map(\.id), [alfred.id])
        XCTAssertEqual(unlent.first?.model, "sonnet")
        XCTAssertEqual(unlent.first?.lent, ["haiku", "opus"])
        XCTAssertEqual(unlent.first?.owner, f.ada.id)
        XCTAssertEqual(unlent.first?.plan, f.hub.access.plans[1].id)
        XCTAssertThrowsError(try f.hub.bots.changeModel(of: alfred.id, to: "sonnet"))
        try f.hub.bots.changeModel(of: alfred.id, to: "opus")
        XCTAssertEqual(f.hub.bots.unlentModels(), [])
        let agent = try XCTUnwrap(f.hub.repository.loadAgents().first { $0.id == alfred.id })
        XCTAssertEqual(agent.modelIdentifier, "opus")
        XCTAssertEqual(agent.displayName, "Alfred")
        guard case .bots(let bots) = try await f.device.request(.bots) else { return XCTFail("no bots") }
        XCTAssertNotEqual(bots.first { $0.id == alfred.id }?.phase, .failed)
        // A harness the plan stopped lending is not fixed by another model, so it is not listed.
        f.hub.access.setModels(["haiku"], for: claude, in: f.hub.access.plans[1])
        XCTAssertEqual(f.hub.bots.unlentModels().map(\.id), [alfred.id])
        f.hub.access.set(claude, included: false, in: f.hub.access.plans[1])
        XCTAssertEqual(f.hub.bots.unlentModels(), [])
    }

    /// A bot without a model runs on the harness default, whichever models the plan lists.
    func testABotWithoutAModelRunsOnTheHarnessDefault() async throws {
        let f = try await fixture()
        f.hub.access.setModels(["sonnet"], for: claude, in: f.hub.access.plans[1])
        let bot = try await createBot(f)
        _ = try await f.device.request(.send(LinkOutgoingMessage(conversationID: bot.conversationID, id: UUID(), body: "Hi")))
    }

    /// A bot the plan no longer lends does not keep a group's message from the others.
    func testAGroupMessageGoesToTheBotsThatCanTakeIt() async throws {
        let f = try await fixture()
        f.hub.access.setModels(["sonnet", "haiku"], for: claude, in: f.hub.access.plans[1])
        guard case .bot(let alfred) = try await f.device.request(.createBot(LinkBotDraft(name: "Alfred", provider: "claude-code", model: "sonnet"))),
              case .bot(let jeeves) = try await f.device.request(.createBot(LinkBotDraft(name: "Jeeves", provider: "claude-code", model: "haiku"))) else {
            return XCTFail("no bots")
        }
        let group = try await createGroup(f, of: [alfred, jeeves])
        f.hub.access.setModels(["haiku"], for: claude, in: f.hub.access.plans[1])
        _ = try await f.device.request(.send(LinkOutgoingMessage(conversationID: group.id, id: UUID(), body: "Dinner at eight.")))
        guard case .messages(let page) = try await f.device.request(.messages(conversationID: group.id, after: 0)) else {
            return XCTFail("no messages")
        }
        XCTAssertEqual(page.messages.map(\.body), ["Dinner at eight."])
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

    /// A bot taking a message changes no count, yet the devices still show it delivered, reply or not.
    func testTakingAMessageIsPushedToTheOwnersDevices() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        let events = try await f.device.subscribe()
        _ = try await f.device.request(.send(LinkOutgoingMessage(conversationID: bot.conversationID, id: UUID(), body: "Hello", attachmentIDs: [])))
        f.hub.bots.checkForChanges()
        try await expect("the message", in: events) { if case .conversationChanged(bot.conversationID, 1) = $0 { true } else { false } }

        _ = try f.hub.repository.latestMessages(for: bot.id)
        f.hub.bots.checkForChanges()
        try await expect("the delivery", in: events) { if case .conversationChanged(bot.conversationID, 1) = $0 { true } else { false } }
        guard case .messages(let page) = try await f.device.request(.messages(conversationID: bot.conversationID, after: 0)) else {
            return XCTFail("no messages")
        }
        XCTAssertEqual(page.messages.map(\.delivered), [true])
    }

    /// A pin made on one device shows on all of the user's devices, in the order they were pinned, and no one else's.
    func testPinsAreKeptOnTheHub() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        guard case .group(let group) = try await f.device.request(.createGroup(LinkGroupDraft(name: "House", botIDs: [bot.id]))) else {
            return XCTFail("no group")
        }
        XCTAssertNil(bot.pinnedAt)
        let phone = HubPairing(directory: FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-phone-\(UUID())"),
                               deviceName: "Phone")
        await phone.join(f.link.invite(f.ada).url().absoluteString)
        let events = try await phone.subscribe()

        let answer = try await f.device.request(.pin(LinkPin(conversationID: group.id, pinned: true)))
        XCTAssertEqual(answer, .done)
        var heard: Date?
        for try await event in events {
            if case .pinChanged(group.id, let pinnedAt) = event { heard = pinnedAt; break }
        }
        XCTAssertNotNil(heard)
        _ = try await phone.request(.pin(LinkPin(conversationID: bot.conversationID, pinned: true)))
        guard case .bots(let bots) = try await phone.request(.bots), case .groups(let groups) = try await phone.request(.groups) else {
            return XCTFail("no lists")
        }
        let groupPin = try XCTUnwrap(groups.first?.pinnedAt), botPin = try XCTUnwrap(bots.first?.pinnedAt)
        XCTAssertLessThanOrEqual(groupPin, botPin)
        // Pinning again keeps its place.
        _ = try await phone.request(.pin(LinkPin(conversationID: group.id, pinned: true)))
        guard case .groups(let again) = try await phone.request(.groups) else { return XCTFail("no groups") }
        XCTAssertEqual(again.first?.pinnedAt, groupPin)

        _ = try await phone.request(.pin(LinkPin(conversationID: group.id, pinned: false)))
        guard case .groups(let unpinned) = try await f.device.request(.groups) else { return XCTFail("no groups") }
        XCTAssertNil(unpinned.first?.pinnedAt)

        let grace = try f.hub.access.addUser(named: "Grace")
        let other = HubPairing(directory: FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-other-\(UUID())"),
                               deviceName: "Other")
        await other.join(f.link.invite(grace).url().absoluteString)
        do {
            _ = try await other.request(.pin(LinkPin(conversationID: bot.conversationID, pinned: true)))
            XCTFail("Pinned another user's conversation")
        } catch {}
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

    /// Muting a group on one device mutes it on all of them: what it showed on a device away is taken back,
    /// and its replies notify nothing until it is unmuted. A bot's own conversation and other people's groups cannot be muted.
    func testAMutedGroupNotifiesNoDevice() async throws {
        let pushes = RecordedPushes()
        let f = try await fixture(pushes: pushes)
        let bot = try await createBot(f)
        let group = try await createGroup(f, of: [bot])
        XCTAssertNil(group.notifications)
        _ = try f.hub.repository.sendAgentMessage(agentID: bot.id, conversationID: group.id, body: "Already here.")
        _ = try await f.device.request(.pushTopic(LinkPushTopic(topic: "phone-topic")))
        f.hub.bots.checkForChanges()
        _ = try f.hub.repository.sendAgentMessage(agentID: bot.id, conversationID: group.id, body: "Dinner is served.")
        f.hub.bots.checkForChanges()
        for _ in 0..<50 where await pushes.unread("phone-topic", group.id) != 2 { try await Task.sleep(for: .milliseconds(100)) }
        let shown = await pushes.unread("phone-topic", group.id)
        XCTAssertEqual(shown, 2)

        let answer = try await f.device.request(.setNotifications(LinkNotificationsChange(conversationID: group.id, notifications: .muted)))
        XCTAssertEqual(answer, .done)
        for _ in 0..<50 where await pushes.unread("phone-topic", group.id) != nil { try await Task.sleep(for: .milliseconds(100)) }
        let afterMuting = await pushes.unread("phone-topic", group.id)
        XCTAssertNil(afterMuting, "Muting takes back what the group showed")
        guard case .groups(let listed) = try await f.device.request(.groups) else { return XCTFail("no groups") }
        XCTAssertEqual(listed.first?.notifications, .muted)
        XCTAssertTrue(f.hub.bots.isMuted(group.id))

        _ = try f.hub.repository.sendAgentMessage(agentID: bot.id, conversationID: group.id, body: "The soup is cold.")
        f.hub.bots.checkForChanges()
        try await Task.sleep(for: .milliseconds(300))
        let whileMuted = await pushes.published.count
        XCTAssertEqual(whileMuted, 1, "A muted group notifies nothing")

        // Unmuted, what waited is not news; the next reply is.
        _ = try await f.device.request(.setNotifications(LinkNotificationsChange(conversationID: group.id, notifications: .default)))
        guard case .groups(let unmuted) = try await f.device.request(.groups) else { return XCTFail("no groups") }
        XCTAssertNil(unmuted.first?.notifications)
        _ = try f.hub.repository.sendAgentMessage(agentID: bot.id, conversationID: group.id, body: "Shall I warm it?")
        f.hub.bots.checkForChanges()
        for _ in 0..<50 where await pushes.unread("phone-topic", group.id) != 4 { try await Task.sleep(for: .milliseconds(100)) }
        let afterUnmuting = await pushes.unread("phone-topic", group.id)
        XCTAssertEqual(afterUnmuting, 4)
        let publishedAgain = await pushes.published.count
        XCTAssertEqual(publishedAgain, 2)

        do {
            _ = try await f.device.request(.setNotifications(LinkNotificationsChange(conversationID: bot.conversationID, notifications: .muted)))
            XCTFail("Muted a bot's own conversation")
        } catch {}
        let grace = try f.hub.access.addUser(named: "Grace")
        let other = HubPairing(directory: FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-other-\(UUID())"),
                               deviceName: "Other")
        await other.join(f.link.invite(grace).url().absoluteString)
        do {
            _ = try await other.request(.setNotifications(LinkNotificationsChange(conversationID: group.id, notifications: .muted)))
            XCTFail("Muted another user's group")
        } catch {}
    }

    /// In Mentions only, a device away hears only of replies naming the user, whether the group or all their groups
    /// are set so. Choosing it takes back what was shown, a group's own level wins, and Muted is silent even for a mention.
    func testMentionsOnlyNotifiesOnlyWhenTheUserIsNamed() async throws {
        let pushes = RecordedPushes()
        let f = try await fixture(pushes: pushes)
        let bot = try await createBot(f)
        let group = try await createGroup(f, of: [bot])
        let say = { (body: String) in
            _ = try f.hub.repository.sendAgentMessage(agentID: bot.id, conversationID: group.id, body: body)
            f.hub.bots.checkForChanges()
        }
        try say("Already here.")
        _ = try await f.device.request(.pushTopic(LinkPushTopic(topic: "phone-topic")))
        try say("Dinner is served.")
        for _ in 0..<50 where await pushes.unread("phone-topic", group.id) != 2 { try await Task.sleep(for: .milliseconds(100)) }
        let shown = await pushes.unread("phone-topic", group.id)
        XCTAssertEqual(shown, 2)

        guard case .status(let status) = try await f.device.request(.setGroupNotifications(.mentions)) else { return XCTFail("no status") }
        XCTAssertTrue(status.notifiesMentions)
        XCTAssertEqual(status.groupNotifications, .mentions)
        XCTAssertEqual(f.hub.access.users.first { $0.id == f.ada.id }?.groupNotifications, .mentions)
        for _ in 0..<50 where await pushes.unread("phone-topic", group.id) != nil { try await Task.sleep(for: .milliseconds(100)) }
        let afterChoosing = await pushes.unread("phone-topic", group.id)
        XCTAssertNil(afterChoosing, "Nothing waiting names Ada, so what was shown goes")

        try say("Adam would like soup from Canada.")
        try await Task.sleep(for: .milliseconds(300))
        let unnamed = await pushes.published.count
        XCTAssertEqual(unnamed, 1, "A reply not naming Ada notifies nothing")
        try say("Ada, the soup is ready.")
        for _ in 0..<50 where await pushes.unread("phone-topic", group.id) != 1 { try await Task.sleep(for: .milliseconds(100)) }
        let named = await pushes.unread("phone-topic", group.id)
        XCTAssertEqual(named, 1, "Only the reply naming her counts")

        _ = try await f.device.request(.setNotifications(LinkNotificationsChange(conversationID: group.id, notifications: .all)))
        guard case .groups(let listed) = try await f.device.request(.groups) else { return XCTFail("no groups") }
        XCTAssertEqual(listed.first?.notifications, .all)
        try say("More bread?")
        for _ in 0..<50 where await pushes.unread("phone-topic", group.id) != 5 { try await Task.sleep(for: .milliseconds(100)) }
        let everyReply = await pushes.unread("phone-topic", group.id)
        XCTAssertEqual(everyReply, 5, "The group's own All Messages wins")

        _ = try await f.device.request(.setNotifications(LinkNotificationsChange(conversationID: group.id, notifications: .muted)))
        for _ in 0..<50 where await pushes.unread("phone-topic", group.id) != nil { try await Task.sleep(for: .milliseconds(100)) }
        try say("Ada, are you there?")
        try await Task.sleep(for: .milliseconds(300))
        let whileMuted = await pushes.published.count
        XCTAssertEqual(whileMuted, 3, "Muted is silent even for a mention")

        _ = try await f.device.request(.setNotifications(LinkNotificationsChange(conversationID: group.id, notifications: .default)))
        guard case .groups(let reset) = try await f.device.request(.groups) else { return XCTFail("no groups") }
        XCTAssertNil(reset.first?.notifications)
        try say("Ada?")
        for _ in 0..<50 where await pushes.unread("phone-topic", group.id) != 3 { try await Task.sleep(for: .milliseconds(100)) }
        let byDefault = await pushes.unread("phone-topic", group.id)
        XCTAssertEqual(byDefault, 3, "Back on the default, the mentions waiting count")

        do {
            _ = try await f.device.request(.setGroupNotifications(.muted))
            XCTFail("Muted every group")
        } catch {}
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

    /// A bot's open tasks reach its owner's devices with the bot, and they hear when they change.
    func testBotsCarryTheirOpenTasks() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        XCTAssertEqual(bot.tasks, [])
        let events = try await f.device.subscribe()
        _ = try await f.device.request(.bots)
        let venue = try f.hub.repository.addTask(agentID: bot.id, title: "Find a venue", conversationID: bot.conversationID)
        _ = try f.hub.repository.updateTask(agentID: bot.id, id: venue.id, state: .waiting, waitingOn: .user, note: "Pick one")
        let done = try f.hub.repository.addTask(agentID: bot.id, title: "Book the dentist")
        _ = try f.hub.repository.updateTask(agentID: bot.id, id: done.id, state: .done)
        f.hub.bots.tasksChanged(of: bot.id)
        for try await event in events { if case .botsChanged = event { break } }

        guard case .bots(let listed) = try await f.device.request(.bots) else { return XCTFail("no bots") }
        let tasks = try XCTUnwrap(listed.first?.tasks)
        XCTAssertEqual(tasks.map(\.title), ["Find a venue"], "Finished tasks stay on the Hub.")
        XCTAssertEqual(tasks.first?.state, .waiting)
        XCTAssertEqual(tasks.first?.waitingOn, .you)
        XCTAssertEqual(tasks.first?.note, "Pick one")
        XCTAssertEqual(tasks.first?.conversationID, bot.conversationID)
    }

    /// Writing from a task carries it to the bot, and back to devices for the label.
    func testAMessageAboutATaskCarriesIt() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        let task = try f.hub.repository.addTask(agentID: bot.id, title: "Find a venue", conversationID: bot.conversationID)
        guard case .message(let sent) = try await f.device.request(.send(LinkOutgoingMessage(
            conversationID: bot.conversationID, id: UUID(), body: "The second one", taskID: task.id))) else { return XCTFail("not sent") }
        XCTAssertEqual(sent.task, LinkTaskReference(id: task.id, botID: bot.id, title: "Find a venue"))
        let stored = try XCTUnwrap(f.hub.repository.loadMessages(conversationID: bot.conversationID).last)
        XCTAssertEqual(stored.task, TaskReference(task, agentID: bot.id))
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
        _ = try await f.device.request(.send(LinkOutgoingMessage(conversationID: bot.conversationID, id: UUID(), body: "Hello", attachmentIDs: [])))
        guard case .messages(let page) = try await f.device.request(.messages(conversationID: bot.conversationID, after: 0)) else {
            return XCTFail("no messages")
        }
        XCTAssertEqual(page.messages.last?.body, "Hello")
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

    /// A device shows a conversation's picture from a small copy the Hub makes rather than the whole
    /// file; a file with nothing to show has none, and someone else's conversation is refused.
    func testAFilesPreviewIsASmallCopyForItsConversationOnly() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        let context = try XCTUnwrap(CGContext(data: nil, width: 2000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2000, height: 1000))
        let photo = FileManager.default.temporaryDirectory.appendingPathComponent("hub-preview-\(UUID()).png")
        addTeardownBlock { try? FileManager.default.removeItem(at: photo) }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(photo as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let size = try XCTUnwrap(photo.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let picture = LinkAttachment(id: UUID(), filename: "Red.png", mediaType: "image/png", byteCount: size)
        try await f.device.upload(photo, as: picture, to: bot.conversationID)

        let ask = LinkRequest.attachmentPreview(conversationID: bot.conversationID, attachmentID: picture.id, pixels: 720)
        guard case .picture(let preview?) = try await f.device.request(ask) else { return XCTFail("No preview") }
        let image = try XCTUnwrap(CGImageSourceCreateWithData(preview as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(image.width, 720)
        XCTAssertEqual(image.height, 360)
        XCTAssertLessThan(preview.count, size)

        let note = LinkAttachment(id: UUID(), filename: "Note.txt", mediaType: "text/plain", byteCount: 3)
        _ = try await f.device.request(.upload(conversationID: bot.conversationID, attachment: note, offset: 0, data: Data("cat".utf8)))
        let none = try await f.device.request(.attachmentPreview(conversationID: bot.conversationID, attachmentID: note.id, pixels: 720))
        XCTAssertEqual(none, .picture(nil))

        let (_, stranger) = try await person("Grace", f)
        do {
            _ = try await stranger.request(ask)
            XCTFail("Someone else's file was previewed")
        } catch {}
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

    /// The comment on a marked-up picture reaches the bot with what it refers to, and devices get it back.
    func testCommentsOnFilesKeepWhatTheyReferTo() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        guard case .status(let status) = try await f.device.request(.status) else { return XCTFail("no status") }
        XCTAssertTrue(status.keepsAnnotations)
        // It says why a bot is paused, so a device trusts a bot listed without a pause to run.
        XCTAssertTrue(status.explainsPauses)
        let photo = LinkAttachment(id: UUID(), filename: "Photo.png", mediaType: "image/png", byteCount: 3)
        let region = LinkAnnotation.Region(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
        let comment = LinkAnnotation(version: 2, sourceAttachmentID: photo.id, sourceFilename: "Photo.png", comment: "Crop here", region: region)
        let marked = LinkAttachment(id: UUID(), filename: "Annotation — Photo.png", mediaType: "image/png", byteCount: 3, annotation: comment)
        // A comment that says nothing is no comment: its file still arrives, as a plain file.
        let blank = LinkAttachment(id: UUID(), filename: "Annotation — Photo 2.png", mediaType: "image/png", byteCount: 3,
                                   annotation: LinkAnnotation(version: 2, sourceAttachmentID: photo.id, sourceFilename: "Photo.png",
                                                              comment: " ", region: region))
        for file in [photo, marked, blank] {
            _ = try await f.device.request(.upload(conversationID: bot.conversationID, attachment: file, offset: 0, data: Data([1, 2, 3])))
        }
        guard case .message(let sent) = try await f.device.request(.send(LinkOutgoingMessage(
            conversationID: bot.conversationID, id: UUID(), body: "Like this", attachmentIDs: [photo.id, marked.id, blank.id]))) else {
            return XCTFail("no message")
        }
        XCTAssertEqual(sent.attachments.map(\.annotation), [nil, comment, nil])
        // The bot reads the comment from the stored file.
        let stored = try f.hub.repository.loadAttachments(conversationID: bot.conversationID)
        let note = try XCTUnwrap(stored.first { $0.id == marked.id }?.annotation)
        XCTAssertEqual(note.comment, "Crop here")
        XCTAssertEqual(note.sourceAttachmentID, photo.id)
        XCTAssertEqual(note.region, AttachmentAnnotation.Region(x: 0.25, y: 0.5, width: 0.5, height: 0.25))
        XCTAssertNil(try XCTUnwrap(stored.first { $0.id == blank.id }).annotation)
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

    private struct MasculineNames: VoicePresentationGuessing {
        func presentation(forName name: String) async -> VoicePresentation? { .masculine }
    }

    /// Someone a bot is shared with calls it as they talk with it: on its owner's plan, in their
    /// own conversation with it, which keeps the call.
    func testSomeoneABotIsSharedWithCallsItInTheirOwnConversation() async throws {
        let (runtime, processes) = try fakeRuntime()
        let f = try await fixture(runtime: runtime)
        f.hub.bots.watch()
        f.hub.bots.voiceGuesser = MasculineNames()
        let family = try XCTUnwrap(f.hub.access.plans.first { $0.name == "Family" })
        f.hub.access.set(HubHarness(provider: .codex, profile: nil), included: true, in: family)
        // Devices choose a bot's voice from what its harness offers.
        guard case .status(let status) = try await f.device.request(.status),
              let codex = status.harnesses.first(where: { $0.provider == "codex" }) else { return XCTFail("no codex") }
        XCTAssertEqual(codex.voices.filter { $0.presentation == .feminine }.map(\.id), ["juniper", "maple", "sol", "vale"])
        XCTAssertEqual(codex.voices.first?.name, "Juniper")
        XCTAssertEqual(status.harnesses.first { $0.provider == "claude-code" }?.voices, [])
        guard case .bot(let made) = try await f.device.request(.createBot(LinkBotDraft(name: "Kai", provider: "codex"))) else {
            return XCTFail("no bot")
        }
        let grace = try await person("Grace", f)
        _ = try await share(made, with: [grace.user], f)
        let graceBots = try await bots(of: grace.device)
        let theirs = try XCTUnwrap(graceBots.first { $0.id == made.id })
        XCTAssertTrue(theirs.canCall)
        XCTAssertNotEqual(theirs.conversationID, made.conversationID)

        f.hub.bots.makeCallPeer = { FakeCallPeer() }
        let channel = try await grace.device.channel(.startCall(LinkCallStart(conversationID: theirs.conversationID)))
        await waitUntil { processes().last?.callRequests.count == 1 }
        let process = try XCTUnwrap(processes().last)
        let request = try XCTUnwrap(process.callRequests.first)
        XCTAssertEqual(request.personName, "Grace")
        XCTAssertEqual(request.conversationID, theirs.conversationID)
        XCTAssertEqual(request.voice, "cove")
        process.callEvents?(.started)
        await waitUntil { (try? f.hub.repository.loadMessages(conversationID: theirs.conversationID).contains { $0.call != nil }) == true }
        XCTAssertEqual(try f.hub.repository.loadMessages(conversationID: theirs.conversationID).filter { $0.call != nil }.count, 1)
        XCTAssertEqual(try f.hub.repository.loadMessages(conversationID: made.conversationID).filter { $0.call != nil }.count, 0)
        channel.cancel()
        await waitUntil { process.callEnds == 1 }
        XCTAssertEqual(process.callEnds, 1)
    }

    /// A Hub where Ada's bot Kai runs on Codex, which takes calls.
    private func callingFixture() async throws -> (Fixture, LinkBot, () -> [FakeProcess]) {
        let (runtime, processes) = try fakeRuntime()
        let f = try await fixture(runtime: runtime)
        f.hub.bots.watch()
        f.hub.bots.voiceGuesser = MasculineNames()
        f.hub.bots.makeCallPeer = { FakeCallPeer() }
        let family = try XCTUnwrap(f.hub.access.plans.first { $0.name == "Family" })
        f.hub.access.set(HubHarness(provider: .codex, profile: nil), included: true, in: family)
        guard case .bot(let made) = try await f.device.request(.createBot(LinkBotDraft(name: "Kai", provider: "codex"))) else {
            throw XCTSkip("unexpected answer")
        }
        return (f, made, processes)
    }

    /// A bot's call rings on its owner's devices, also on one that subscribes while it rings. Answering on one
    /// calls the bot, told why it called, and the others stop ringing.
    func testABotsCallRingsItsOwnersDevicesUntilOneAnswers() async throws {
        let (f, kai, processes) = try await callingFixture()
        let events = try await f.device.subscribe()
        _ = try await f.device.request(.status)
        let request = try f.hub.repository.requestCall(agentID: kai.id, reason: "The build is broken")
        f.hub.bots.ringCall(of: kai.id)
        let conversation = kai.conversationID, bot = kai.id
        // Seconds left, not a time, so a device with its clock off rings as long.
        let rang: @Sendable (LinkEvent) -> Bool = {
            guard case .callRinging(let call) = $0 else { return false }
            return call.id == request.id && call.botID == bot && call.conversationID == conversation
                && call.reason == "The build is broken" && (40...45).contains(call.secondsLeft)
        }
        try await expect("the call ringing", in: events, where: rang)
        XCTAssertTrue(processes().isEmpty, "Nothing connects to the bot before the call is answered")

        let phone = HubPairing(directory: FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-phone-\(UUID())"),
                               deviceName: "iPhone")
        addTeardownBlock { try? FileManager.default.removeItem(at: phone.directory) }
        await phone.join(f.link.invite(f.ada).url().absoluteString)
        let phoneEvents = try await phone.subscribe()
        try await expect("the call ringing on a device that subscribed later", in: phoneEvents, where: rang)

        let channel = try await phone.channel(.startCall(LinkCallStart(conversationID: kai.conversationID, answering: request.id)))
        try await expect("the call stopping on the other device", in: events) { $0 == .callStopped(id: request.id) }
        await waitUntil { processes().last?.callRequests.count == 1 }
        XCTAssertEqual(processes().last?.callRequests.first?.answeredCallReason, "The build is broken")
        XCTAssertNil(f.hub.repository.pendingCall(agentID: kai.id))
        XCTAssertTrue(f.hub.bots.ringingCalls(for: f.ada.id).isEmpty)
        channel.cancel()
    }

    /// Only the bot's owner declines its call, which leaves a card; so does a call nobody answers in time.
    func testADeclinedOrUnansweredCallLeavesACardOnEveryDevice() async throws {
        let (f, kai, _) = try await callingFixture()
        let grace = try await person("Grace", f)
        let events = try await f.device.subscribe()
        _ = try await f.device.request(.status)
        let declined = try f.hub.repository.requestCall(agentID: kai.id, reason: "Need a decision")
        f.hub.bots.ringCall(of: kai.id)
        do {
            _ = try await grace.device.request(.declineCall(id: declined.id))
            XCTFail("Declined someone else's call")
        } catch {}
        let answer = try await f.device.request(.declineCall(id: declined.id))
        XCTAssertEqual(answer, .done)
        try await expect("the declined call stopping", in: events) { $0 == .callStopped(id: declined.id) }

        let later = Date().addingTimeInterval(AgentCallLimits.cooldown + 60)
        let missed = try f.hub.repository.requestCall(agentID: kai.id, reason: "The disk is full", now: later)
        f.hub.bots.ringCall(of: kai.id, now: later)
        f.hub.bots.expireCalls(at: missed.expiresAt)
        try await expect("the missed call stopping", in: events) { $0 == .callStopped(id: missed.id) }

        guard case .messages(let page) = try await f.device.request(.messages(conversationID: kai.conversationID, after: 0)) else {
            return XCTFail("no messages")
        }
        let cards = page.messages.compactMap(\.call)
        XCTAssertEqual(cards.map(\.unanswered), [.declined, .missed])
        XCTAssertEqual(cards.map(\.reason), ["Need a decision", "The disk is full"])
        XCTAssertNil(f.hub.repository.pendingCall(agentID: kai.id))
    }

    private func callCards(_ f: Fixture, _ bot: LinkBot) -> [VoiceCallRecord] {
        ((try? f.hub.repository.loadMessages(conversationID: bot.conversationID)) ?? []).compactMap(\.call)
    }

    /// Calls that rang when the Hub stopped ring on when it starts again, or are left missed with a card.
    func testCallsPendingWhenTheHubStartsAgainRingOnOrAreLeftMissed() async throws {
        let (f, kai, _) = try await callingFixture()
        let events = try await f.device.subscribe()
        _ = try await f.device.request(.status)
        _ = try f.hub.repository.requestCall(agentID: kai.id, reason: "Rang while the Hub was off",
                                            now: Date().addingTimeInterval(-AgentCallLimits.ringing - 10))
        f.hub.bots.ringPendingCalls()
        XCTAssertEqual(callCards(f, kai).map(\.unanswered), [.missed])
        XCTAssertNil(f.hub.repository.pendingCall(agentID: kai.id))

        let later = Date().addingTimeInterval(AgentCallLimits.cooldown + 60)
        let ringing = try f.hub.repository.requestCall(agentID: kai.id, reason: "Still ringing", now: later)
        f.hub.bots.ringPendingCalls(now: later)
        let id = ringing.id
        try await expect("the call ringing on", in: events) { if case .callRinging(let call) = $0 { call.id == id } else { false } }
    }

    /// A call answered that never connects is left missed, so the bot hears of it. Declining a call that
    /// no longer rings does nothing.
    func testAnAnsweredCallThatNeverConnectsIsLeftMissed() async throws {
        let (f, kai, processes) = try await callingFixture()
        let request = try f.hub.repository.requestCall(agentID: kai.id, reason: "The build is broken")
        f.hub.bots.ringCall(of: kai.id)
        let channel = try await f.device.channel(.startCall(LinkCallStart(conversationID: kai.conversationID, answering: request.id)))
        await waitUntil { processes().last?.callRequests.count == 1 }
        XCTAssertTrue(callCards(f, kai).isEmpty)
        processes().last?.callEvents?(.ended("The voice did not start."))
        await waitUntil { !self.callCards(f, kai).isEmpty }
        XCTAssertEqual(callCards(f, kai).map(\.unanswered), [.missed])
        XCTAssertEqual(callCards(f, kai).map(\.reason), ["The build is broken"])
        let late = try await f.device.request(.declineCall(id: request.id))
        XCTAssertEqual(late, .done)
        XCTAssertEqual(callCards(f, kai).count, 1)
        channel.cancel()
    }

    /// What else rings a call, Noodle on the owner's own Mac, hears when it stops here, and stops it ringing
    /// on every device when it ended there, which leaves no second card.
    func testACallEndedElsewhereStopsRingingAndOneEndedHereSaysSo() async throws {
        let (f, kai, processes) = try await callingFixture()
        var stopped: [UUID] = []
        f.hub.bots.onCallStopped = { stopped.append($0) }
        let events = try await f.device.subscribe()
        _ = try await f.device.request(.status)

        let elsewhere = try f.hub.repository.requestCall(agentID: kai.id, reason: "Answered on the Mac")
        f.hub.bots.ringCall(of: kai.id)
        _ = try f.hub.repository.endCall(agentID: kai.id, id: elsewhere.id)
        f.hub.bots.stopRinging(elsewhere.id)
        f.hub.bots.stopRinging(elsewhere.id)
        let elsewhereID = elsewhere.id
        try await expect("the call stopping", in: events) { $0 == .callStopped(id: elsewhereID) }
        XCTAssertTrue(f.hub.bots.ringingCalls(for: f.ada.id).isEmpty)
        f.hub.bots.expireCalls(at: elsewhere.expiresAt)
        XCTAssertEqual(stopped, [], "It stopped elsewhere, which already knows")
        XCTAssertTrue(callCards(f, kai).isEmpty)

        // A day apart, so the daily limit lets each call through.
        let day: TimeInterval = 24 * 60 * 60 + 60
        var later = Date().addingTimeInterval(day)
        let declined = try f.hub.repository.requestCall(agentID: kai.id, reason: "Need a decision", now: later)
        f.hub.bots.ringCall(of: kai.id, now: later)
        _ = try await f.device.request(.declineCall(id: declined.id))
        XCTAssertEqual(stopped, [declined.id])

        later = later.addingTimeInterval(day)
        let missed = try f.hub.repository.requestCall(agentID: kai.id, reason: "The disk is full", now: later)
        f.hub.bots.ringCall(of: kai.id, now: later)
        f.hub.bots.expireCalls(at: missed.expiresAt)
        XCTAssertEqual(stopped, [declined.id, missed.id])

        later = later.addingTimeInterval(day)
        let answered = try f.hub.repository.requestCall(agentID: kai.id, reason: "The build is broken", now: later)
        f.hub.bots.ringCall(of: kai.id, now: later)
        let channel = try await f.device.channel(.startCall(LinkCallStart(conversationID: kai.conversationID, answering: answered.id)))
        await waitUntil { processes().last?.callRequests.count == 1 }
        XCTAssertEqual(stopped, [declined.id, missed.id, answered.id])
        XCTAssertEqual(callCards(f, kai).map(\.unanswered), [.declined, .missed])
        channel.cancel()
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

    /// A chat effect a bot sends waits until one of its person's devices shows the conversation; that device
    /// takes it, so it plays once, and nobody else can.
    func testAChatEffectWaitsForADeviceToShowTheConversation() async throws {
        let f = try await fixture()
        let bot = try await createBot(f)
        let phone = HubPairing(directory: FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-phone-\(UUID())"),
                               deviceName: "iPhone")
        addTeardownBlock { try? FileManager.default.removeItem(at: phone.directory) }
        await phone.join(f.link.invite(f.ada).url().absoluteString)
        let grace = try await person("Grace", f)
        let events = try await f.device.subscribe()
        _ = try await f.device.request(.status)
        f.hub.bots.checkForChanges()

        let sent = try f.hub.repository.sendEffect(agentID: bot.id, conversationID: bot.conversationID, kind: "confetti")
        f.hub.bots.checkForChanges()
        let conversation = bot.conversationID
        try await expect("that an effect waits", in: events) { if case .effectWaiting(conversation) = $0 { true } else { false } }
        do {
            _ = try await grace.device.request(.takeEffect(conversationID: bot.conversationID))
            XCTFail("Took an effect from someone else's conversation")
        } catch {}
        let taken = try await phone.request(.takeEffect(conversationID: bot.conversationID))
        XCTAssertEqual(taken, .effect(LinkEffect(id: sent.id, kind: "confetti")))
        let again = try await f.device.request(.takeEffect(conversationID: bot.conversationID))
        XCTAssertEqual(again, .effect(nil), "It plays on one device only")
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
            .organize(botID: bot.id),
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
        _ = try await grace.device.request(.send(LinkOutgoingMessage(conversationID: graces.conversationID, id: UUID(), body: "Hi")))
        guard case .messages(let page) = try await grace.device.request(.messages(conversationID: graces.conversationID, after: 0)) else {
            return XCTFail("no messages")
        }
        XCTAssertEqual(page.messages.last?.body, "Hi")
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
