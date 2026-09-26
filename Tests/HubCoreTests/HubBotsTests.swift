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
    }

    private let claude = HubHarness(provider: .claudeCode, profile: nil)

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-bots-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(root: root.appendingPathComponent("Hub"), messenger: nil)
        try hub.repository.prepare()
        let link = HubLinkService(hubName: "Mac mini", directory: root.appendingPathComponent("Hub/Link"),
                                  access: hub.access, profiles: hub.harnessProfiles, bots: hub.bots,
                                  connections: hub.connections, port: 0,
                                  localEndpoints: { [LinkEndpoint(host: "::1", port: $0)] })
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
        return Fixture(hub: hub, link: link, ada: ada, device: device)
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
