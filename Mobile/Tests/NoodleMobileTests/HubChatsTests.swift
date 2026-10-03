import CloudKit
import Foundation
import HubLink
import NoodleWallpaperCore
import UIKit
@testable import NoodleMobile
import SwiftUI
import Testing

/// A Hub with one bot that answers every message, reached over QUIC like the real one.
private actor FakeHub {
    var bot = LinkBot(id: UUID(), conversationID: UUID(),
                      draft: LinkBotDraft(name: "Scout", provider: "claude"), createdAt: Date(timeIntervalSince1970: 0))
    var created: [LinkBot] = []
    var groups: [LinkGroup] = []
    /// Files by ID, as uploaded or given to the bot's messages.
    var files: [UUID: (attachment: LinkAttachment, data: Data)] = [:]
    var downloads = 0
    var pictureFetches = 0
    /// Bot edits as the phone sent them.
    var edits: [LinkBotDraft] = []
    /// Where the phone asked to hear of unread replies, in order.
    var pushTopics: [String?] = []
    var messages: [LinkMessage] = []
    /// Where it listens, which it tells the phone when pairing, as the real Hub does.
    var endpoints: [LinkEndpoint] = []

    /// Sends answered with a timeout. When `keepsFailedSends`, the message is taken all the same, as when only the answer is lost.
    var failingSends = 0
    var keepsFailedSends = false

    func listen(at endpoint: LinkEndpoint) { endpoints = [endpoint] }

    func failSends(_ count: Int, keeping: Bool = false) {
        failingSends = count
        keepsFailedSends = keeping
    }

    func bodies(saying body: String) -> Int { messages.count { $0.body == body } }

    func setPicture(_ data: Data) { bot.draft.avatarImageData = data }

    func setStatus(_ status: String?) { bot.status = status }

    /// The small copies of background files the phone asks for, by media name.
    var backgroundFiles: [String: Data] = [:]
    var backgroundFetches = 0
    /// A background's pieces as they arrive.
    var backgroundUpload = Data()

    func setBackground(_ background: LinkBackground, compact: Data? = nil) {
        bot.background = background
        if let media = background.media { backgroundFiles[media] = compact }
    }

    /// A group of Scout, made on another device, with something already said in it.
    func addGroup(named name: String, saying body: String) -> LinkGroup {
        let group = LinkGroup(id: UUID(), draft: LinkGroupDraft(name: name, botIDs: [bot.id]), createdAt: Date(timeIntervalSince1970: 5))
        groups.append(group)
        messages.append(LinkMessage(id: UUID(), conversationID: group.id, author: .bot(bot.id), body: body,
                                    createdAt: Date(timeIntervalSince1970: 30), delivered: true))
        return group
    }

    func data(of id: UUID) -> Data? { files[id]?.data }

    func botSays(_ body: String) {
        messages.append(LinkMessage(id: UUID(), conversationID: bot.conversationID, author: .bot(bot.id), body: body,
                                    createdAt: Date(), delivered: true))
    }

    /// A message from the bot carrying a file.
    func botSends(_ data: Data, named filename: String, mediaType: String) -> LinkAttachment {
        let attachment = LinkAttachment(id: UUID(), filename: filename, mediaType: mediaType, byteCount: data.count)
        files[attachment.id] = (attachment, data)
        messages.append(LinkMessage(id: UUID(), conversationID: bot.conversationID, author: .bot(bot.id), body: "Here it is",
                                    createdAt: Date(timeIntervalSince1970: 20), delivered: true, attachments: [attachment]))
        return attachment
    }

    init() {
        messages = [LinkMessage(id: UUID(), conversationID: bot.conversationID, author: .bot(bot.id), body: "Hello",
                                createdAt: Date(timeIntervalSince1970: 10), delivered: true)]
    }

    func reply(to data: Data) -> LinkResponse {
        switch LinkProtocol.decode(data) {
        case .success(.enroll):
            return .status(LinkStatus(hubName: "Studio", userName: "Petko", planName: "", harnesses: [], endpoints: endpoints))
        case .success(.bots):
            // As the real Hub answers a device that fetches pictures itself.
            return .bots(([bot] + created).map(\.withoutPicture))
        case .success(.picture(.bot(let id))) where id == bot.id:
            pictureFetches += 1
            return .picture(bot.draft.avatarImageData)
        case .success(.updateBot(let id, let draft)) where id == bot.id:
            edits.append(draft)
            let picture = draft.avatarImageData ?? (draft.avatarImageDigest == nil ? nil : bot.draft.avatarImageData)
            bot.draft = draft
            bot.draft.avatarImageData = picture
            return .bot(bot)
        case .success(.deleteBot(let id)):
            created.removeAll { $0.id == id }
            return .done
        case .success(.groups):
            return .groups(groups)
        case .success(.createGroup(let draft)):
            let group = LinkGroup(id: UUID(), draft: draft, createdAt: Date())
            groups.append(group)
            return .group(group)
        case .success(.updateGroup(let id, let draft)):
            guard let index = groups.firstIndex(where: { $0.id == id }) else { return .failure("No such group.") }
            groups[index].draft = draft
            return .group(groups[index])
        case .success(.deleteGroup(let id)):
            groups.removeAll { $0.id == id }
            return .done
        case .success(.archive(let change)):
            let date: Date? = change.archived ? Date() : nil
            if change.id == bot.id { bot.archivedAt = date }
            else if let index = groups.firstIndex(where: { $0.id == change.id }) { groups[index].archivedAt = date }
            else { return .failure("There is no such bot.") }
            return .done
        case .success(.createBot(let draft)):
            let new = LinkBot(id: UUID(), conversationID: UUID(), draft: draft, createdAt: Date())
            created.append(new)
            return .bot(new)
        case .success(.messages(let conversationID, let after)):
            let messages = messages.filter { $0.conversationID == conversationID }
            return .messages(LinkMessages(messages: Array(messages.dropFirst(after)), count: messages.count))
        case .success(.messagePage(let page)):
            let messages = messages.filter { $0.conversationID == page.conversationID }
            if let after = page.after {
                let start = min(after, messages.count)
                return .messages(LinkMessages(messages: Array(messages[start..<min(start + page.limit, messages.count)]),
                                              count: messages.count, start: start))
            }
            let end = min(page.before ?? messages.count, messages.count), start = max(0, end - page.limit)
            return .messages(LinkMessages(messages: Array(messages[start..<end]), count: messages.count, start: start))
        case .success(.pushTopic(let registration)):
            pushTopics.append(registration.topic)
            return .done
        case .success(.markRead(let mark)):
            guard let message = messages.first(where: { $0.id == mark.messageID }) else { return .failure("No such message.") }
            bot.readUpTo = max(bot.readUpTo ?? .distantPast, message.createdAt)
            return .done
        case .success(.react(let change)):
            guard let index = messages.firstIndex(where: { $0.id == change.messageID }) else { return .failure("No such message.") }
            let reaction = LinkReaction(author: .you, emoji: change.emoji)
            messages[index].reactions.removeAll { $0 == reaction }
            if change.present { messages[index].reactions.append(reaction) }
            return .message(messages[index])
        case .success(.upload(_, let attachment, let offset, let data)):
            var file = files[attachment.id] ?? (attachment, Data())
            guard offset == file.data.count else { return .failure("Pieces out of order.") }
            file.data.append(data)
            files[attachment.id] = file
            return .done
        case .success(.download(_, let id, let offset)):
            guard let file = files[id] else { return .failure("No such file.") }
            if offset == 0 { downloads += 1 }
            let end = min(offset + LinkProtocol.chunkSize, file.data.count)
            return .chunk(data: file.data.subdata(in: offset..<end), total: file.data.count)
        case .success(.send) where failingSends > 0 && !keepsFailedSends:
            failingSends -= 1
            return .failure("The Hub did not answer in time.")
        case .success(.send(let outgoing)):
            if messages.contains(where: { $0.id == outgoing.id }) { return .message(messages.first { $0.id == outgoing.id }!) }
            let attachments = outgoing.attachmentIDs.compactMap { files[$0]?.attachment }
            guard attachments.count == outgoing.attachmentIDs.count else { return .failure("A file is missing.") }
            let sent = LinkMessage(id: outgoing.id, conversationID: bot.conversationID, author: .you, body: outgoing.body,
                                   createdAt: Date(), delivered: true, attachments: attachments)
            messages.append(sent)
            messages.append(LinkMessage(id: UUID(), conversationID: bot.conversationID, author: .bot(bot.id),
                                        body: "You said: \(outgoing.body)", createdAt: Date(), delivered: true))
            if failingSends > 0 {
                failingSends -= 1
                return .failure("The Hub did not answer in time.")
            }
            return .message(sent)
        case .success(.setBackground(let choice)) where choice.conversationID == bot.conversationID:
            bot.background = LinkBackground(preset: choice.preset)
            return .background(bot.background!)
        case .success(.uploadBackground(let piece)) where piece.conversationID == bot.conversationID:
            if piece.offset == 0 { backgroundUpload = Data() }
            guard piece.offset == backgroundUpload.count else { return .failure("Pieces out of order.") }
            backgroundUpload.append(piece.data)
            guard backgroundUpload.count == piece.byteCount else { return .done }
            setBackground(LinkBackground(media: "\(UUID()).jpg", mediaKind: "image"), compact: backgroundUpload)
            return .background(bot.background!)
        case .success(.backgroundMedia(let fetch)) where fetch.conversationID == bot.conversationID && fetch.compact:
            guard fetch.media == bot.background?.media, let data = backgroundFiles[fetch.media] else { return .failure("No such background.") }
            if fetch.offset == 0 { backgroundFetches += 1 }
            let end = min(fetch.offset + LinkProtocol.chunkSize, data.count)
            return .chunk(data: data.subdata(in: fetch.offset..<end), total: data.count)
        case .success(.kick(let id)) where id == bot.id:
            restarts.append("kick")
            return kickConfirmation.map(LinkResponse.kickConfirmation) ?? .done
        case .success(.confirmKick(let id, let confirmationID)) where id == bot.id:
            restarts.append("confirm \(confirmationID)")
            return .done
        case .success(.newSession(let id)) where id == bot.id:
            restarts.append("new session")
            return .done
        default:
            return .failure("Not in this test.")
        }
    }

    /// Kick, confirmations and new sessions, as the phone asked for them.
    var restarts: [String] = []
    /// What Kick asks first, or nil to restart at once.
    var kickConfirmation: LinkKickConfirmation?

    func askBeforeKick(_ confirmation: LinkKickConfirmation?) { kickConfirmation = confirmation }
}

/// Stands in for CloudKit, keeping the topics subscribed to.
private actor RecordedSubscriptions: PushSubscriptions {
    var topics: Set<String> = []
    var failing = false

    func fail() { failing = true }

    func subscribe(topic: String) throws {
        if failing { throw LinkError("Not signed in to iCloud.") }
        topics.insert(topic)
    }

    func unsubscribe(topic: String) { topics.remove(topic) }
}

@MainActor @Suite struct HubChatsTests {
    private func paired(to hub: FakeHub, directory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)) async throws -> (HubChats, LinkServer) {
        let identity = LinkIdentity()
        let server = try LinkServer(identity: identity, port: 0, admits: { _ in true }) { _, data in
            .response(LinkProtocol.encode(await hub.reply(to: data)))
        }
        try await server.start()
        let endpoint = LinkEndpoint(host: "127.0.0.1", port: try #require(server.port))
        await hub.listen(at: endpoint)
        let invitation = LinkInvitation(hubName: "Studio", hubKey: identity.publicKey, endpoints: [endpoint],
                                        userName: "Petko", joinKey: LinkIdentity().privateKey.rawRepresentation, expires: Date().addingTimeInterval(600))
        let pairing = HubPairing(directory: directory, deviceName: "iPhone")
        await pairing.join(invitation.url().absoluteString)
        try #require(pairing.hub != nil)
        return (HubChats(pairing: pairing), server)
    }

    /// Kick restarts at once or brings back the Hub's question, whose answer names it; New Session goes straight through.
    @Test func kickAndNewSessionReachTheHub() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        let scout = await hub.bot

        #expect(try await chats.kick(scout) == nil)
        let question = LinkKickConfirmation(id: UUID(), title: "Safeguards stopped Scout", message: "Stopped.",
                                            confirmTitle: "Resume", offersNewSession: true)
        await hub.askBeforeKick(question)
        let asked = try #require(try await chats.kick(scout))
        #expect(asked == question)
        try await chats.confirmKick(asked, for: scout)
        try await chats.startNewSession(scout)
        #expect(await hub.restarts == ["kick", "kick", "confirm \(question.id)", "new session"])
    }

    /// A long conversation opens on its newest page; scrolling back brings the rest.
    @Test func aLongConversationOpensOnItsNewestPage() async throws {
        let hub = FakeHub()
        for index in 1..<120 { await hub.botSays("Message \(index)") }
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }

        try await chats.reload()
        let scout = try #require(chats.agents.first)
        #expect(chats.messages(of: scout).count == 50)
        #expect(chats.messages(of: scout).last?.body == "Message 119")
        #expect(chats.hasEarlier(scout))
        while chats.hasEarlier(scout) { try await chats.loadEarlier(scout) }
        #expect(chats.messages(of: scout).map(\.body) == ["Hello"] + (1..<120).map { "Message \($0)" })
    }

    /// A message sent before the conversation has loaded still lands after what was already said.
    @Test func messagesKeepTheirOrderWhenSentBeforeTheConversationLoads() async throws {
        let hub = FakeHub()
        await hub.botSays("Earlier")
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }

        try await chats.send("Hi", to: await hub.bot)
        let bodies = chats.messages(of: await hub.bot).map(\.body)
        #expect(Array(bodies.prefix(3)) == ["Hello", "Earlier", "Hi"])
    }

    /// A bot's picture is fetched once, apart from the list, and an edit does not send it back.
    @Test func botPicturesAreFetchedOnceAndNotSentBack() async throws {
        let hub = FakeHub()
        let picture = Data(repeating: 5, count: 2_000_000)
        await hub.setPicture(picture)
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }

        try await chats.reload()
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        #expect(scout.draft.avatarImageData == picture)
        #expect(await hub.pictureFetches == 1)

        var renamed = scout
        renamed.draft.name = "Ranger"
        try await chats.update(renamed)
        #expect(await hub.edits.last?.avatarImageData == nil)
        #expect(await hub.bot.draft.avatarImageData == picture)
        #expect(await hub.bot.draft.name == "Ranger")
    }

    @Test func agentsListWithTheirLatestMessage() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }

        try await chats.reload()

        #expect(chats.agents.map(\.draft.name) == ["Scout"])
        #expect(chats.latestMessage(of: try #require(chats.agents.first))?.body == "Hello")
    }

    @Test func sendingShowsMyMessageAndTheReply() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)

        try await chats.send("Hi there", to: scout)

        #expect(chats.messages(of: scout).map(\.body) == ["Hello", "Hi there", "You said: Hi there"])
        #expect(chats.messages(of: scout)[1].author == .you)
    }

    @Test func aNewAgentIsMadeOnTheHubAndListed() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()

        let agent = try await chats.create(LinkBotDraft(name: "Atlas", provider: "codex"))

        #expect(agent.draft.name == "Atlas")
        #expect(chats.agents.map(\.draft.name).contains("Atlas"))
        #expect(await hub.created.map(\.draft.provider) == ["codex"])
    }

    @Test func pinnedAgentsComeFirstAndStayPinned() async throws {
        let hub = FakeHub()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: directory)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        // A newer agent with no messages sorts above Scout, whose only message is from 1970.
        let atlas = try await chats.create(LinkBotDraft(name: "Atlas", provider: "codex"))
        #expect(chats.sortedThreads.map(\.id) == [atlas.id, scout.id])

        chats.togglePin(scout)

        #expect(chats.isPinned(scout))
        #expect(chats.sortedThreads.map(\.id) == [scout.id, atlas.id])
        let relaunched = HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone"))
        #expect(relaunched.isPinned(scout))
    }

    /// As in the Mac sidebar: by name, description or what was said, ignoring case and accents.
    @Test func searchFindsAgentsByNameDescriptionAndMessages() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        var draft = LinkBotDraft(name: "Zoë", provider: "codex")
        draft.publicDescription = "Keeps the garden"
        let zoe = try await chats.create(draft)
        let cases: [(String, [UUID])] = [
            ("zoe", [zoe.id]), ("SCOUT", [scout.id]), ("  garden ", [zoe.id]), ("hello", [scout.id]),
            ("nobody", []), (" \n ", [zoe.id, scout.id])
        ]
        for (query, expected) in cases {
            #expect(chats.sortedThreads.filter { chats.matches($0, search: query) }.map(\.id) == expected, "\(query)")
        }
    }

    @Test func anEditedAgentShowsItsNewDetails() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        var scout = try #require(chats.agents.first)
        scout.draft.name = "Scout II"

        try await chats.update(scout)

        #expect(chats.agents.map(\.draft.name) == ["Scout II"])
        #expect(await hub.bot.draft.name == "Scout II")
    }

    @Test func aRelaunchShowsWhatWasLastSyncedBeforeTheHubAnswers() async throws {
        let hub = FakeHub()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: directory)
        try await chats.reload()
        #expect(chats.isLoaded)
        server.stop()

        let relaunched = HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone"))

        let scout = try #require(relaunched.agents.first)
        #expect(scout.draft.name == "Scout")
        #expect(relaunched.latestMessage(of: scout)?.body == "Hello")
    }

    @Test func noAgentsIsOnlyKnownOnceTheHubHasAnswered() {
        let chats = HubChats(pairing: HubPairing(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString), deviceName: "iPhone"))
        #expect(chats.agents.isEmpty)
        #expect(!chats.isLoaded)
    }

    /// A draft of nothing but blank lines or spaces is not kept, so the field comes back empty, at its usual size.
    @Test func aBlankDraftIsNotKept() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let chats = HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone"))
        try FileManager.default.createDirectory(at: chats.pairing.directory, withIntermediateDirectories: true)
        let scout = LinkBot(id: UUID(), conversationID: UUID(), draft: LinkBotDraft(name: "Scout", provider: "claude"),
                            createdAt: Date(timeIntervalSince1970: 0))
        let atlas = LinkBot(id: UUID(), conversationID: UUID(), draft: LinkBotDraft(name: "Atlas", provider: "codex"),
                            createdAt: Date(timeIntervalSince1970: 0))
        chats.setDraft("Hello\n", for: scout)
        chats.setDraft("\n", for: scout)
        #expect(chats.draft(for: scout) == "")
        #expect(HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone")).draft(for: scout) == "")

        // One saved before blank drafts were dropped comes back empty too.
        try JSONEncoder().encode([atlas.conversationID: " \n "])
            .write(to: chats.pairing.directory.appendingPathComponent("drafts.json"), options: .atomic)
        #expect(HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone")).draft(for: atlas) == "")
    }

    @Test func aDeletedBotLeavesTheListThePinsAndTheSavedCopy() async throws {
        let hub = FakeHub()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: directory)
        defer { server.stop() }
        try await chats.reload()
        let atlas = try await chats.create(LinkBotDraft(name: "Atlas", provider: "codex"))
        chats.togglePin(atlas)

        try await chats.delete(atlas)

        #expect(!chats.agents.contains { $0.id == atlas.id })
        #expect(!chats.isPinned(atlas))
        #expect(await hub.created.isEmpty)
        let relaunched = HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone"))
        #expect(!relaunched.agents.contains { $0.id == atlas.id })
        #expect(!relaunched.isPinned(atlas))
    }

    @Test func anArchivedBotOrGroupLeavesTheListUntilUnarchived() async throws {
        let hub = FakeHub()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: directory)
        defer { server.stop() }
        let house = await hub.addGroup(named: "House", saying: "Dinner at eight.")
        try await chats.reload()
        let scout = try #require(chats.agents.first)

        try await chats.setArchived(true, .bot(scout))
        #expect(await hub.bot.archivedAt != nil)
        #expect(chats.isArchived(.bot(try #require(chats.agent(scout.id)))))
        #expect(chats.listedThreads.map(\.id) == [house.id])
        #expect(chats.archivedThreads.map(\.id) == [scout.id])
        #expect(chats.composerUnavailableReason(for: .bot(try #require(chats.agent(scout.id)))) == "Scout is archived")
        #expect(chats.composerUnavailableReason(for: .group(house)) == "Every bot in this group is archived")
        #expect(chats.activeMembers(of: house).isEmpty)
        // Kept across a relaunch, before the Hub answers.
        let relaunched = HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone"))
        #expect(relaunched.archivedThreads.map(\.id) == [scout.id])

        try await chats.setArchived(false, .bot(try #require(chats.agent(scout.id))))
        #expect(await hub.bot.archivedAt == nil)
        #expect(Set(chats.listedThreads.map(\.id)) == [scout.id, house.id])

        try await chats.setArchived(true, .group(house))
        #expect(chats.listedThreads.map(\.id) == [scout.id])
        #expect(chats.composerUnavailableReason(for: .group(try #require(chats.groups.first))) == "This group is archived")
        try await chats.reload()
        #expect(chats.archivedThreads.map(\.id) == [house.id])
        try await chats.setArchived(false, .group(try #require(chats.groups.first)))
        #expect(chats.archivedThreads.isEmpty)
    }

    @Test func sentFilesReachTheHubWithTheMessage() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        // Bigger than one piece, so it travels in several.
        let data = Data((0..<(LinkProtocol.chunkSize + 1000)).map { UInt8($0 % 251) })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try data.write(to: file)

        try await chats.send("Look", files: [OutgoingFile(url: file, filename: "photo.png", mediaType: "image/png")], to: scout)

        let sent = try #require(chats.messages(of: scout).first { $0.body == "Look" })
        let attachment = try #require(sent.attachments.first)
        #expect(attachment.filename == "photo.png")
        #expect(await hub.data(of: attachment.id) == data)
        // The phone keeps what it sent, so it never downloads it back.
        #expect(try Data(contentsOf: try await chats.file(for: attachment, in: scout)) == data)
        #expect(await hub.downloads == 0)
    }

    @Test func aBotsFileIsDownloadedOnceAndKept() async throws {
        let hub = FakeHub()
        let attachment = await hub.botSends(Data("report".utf8), named: "report.txt", mediaType: "text/plain")
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        #expect(chats.messages(of: scout).last?.attachments == [attachment])

        let first = try await chats.file(for: attachment, in: scout)
        let second = try await chats.file(for: attachment, in: scout)

        #expect(try Data(contentsOf: first) == Data("report".utf8))
        #expect(first.lastPathComponent == "report.txt")
        #expect(first == second)
        #expect(await hub.downloads == 1)
    }

    @Test func onlyPublicWebLinksGetAPreview() {
        #expect(LinkPreview.firstURL(in: "See https://example.com/page and https://apple.com")?.absoluteString == "https://example.com/page")
        #expect(LinkPreview.firstURL(in: "[docs](https://swift.org/documentation)")?.host() == "swift.org")
        for text in ["http://localhost:8080", "http://192.168.1.4/admin", "mailto:a@b.com", "ftp://example.com", "no links"] {
            #expect(LinkPreview.firstURL(in: text) == nil, "\(text)")
        }
    }

    @Test func conversationsAlreadyThereAreNotUnread() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }

        try await chats.reload()

        #expect(!chats.isUnread(try #require(chats.agents.first)))
    }

    /// A pinned circle's bubble shows the start of an unread reply, or else the bot's status.
    @Test func aPinnedBubbleShowsAnUnreadReplyBeforeTheStatus() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        func note() throws -> PinnedNote? { chats.note(for: .bot(try #require(chats.agents.first))) }
        try await chats.reload()
        #expect(try note() == nil)

        await hub.setStatus("Reviewing PR 42")
        try await chats.reload()
        #expect(try note() == .status("Reviewing PR 42"))

        await hub.botSays("Done,\n  all green")
        try await chats.reload()
        #expect(try note() == .unread("Done, all green"))

        chats.markRead(try #require(chats.agents.first))
        #expect(try note() == .status("Reviewing PR 42"))
    }

    @Test func aReplyIsUnreadUntilTheConversationIsOpened() async throws {
        let hub = FakeHub()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: directory)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)

        await hub.botSays("Done")
        try await chats.reload()
        #expect(chats.isUnread(scout))
        #expect(HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone")).isUnread(scout))

        chats.markRead(scout)

        #expect(!chats.isUnread(scout))
        #expect(!HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone")).isUnread(scout))
    }

    @Test func aLaterReplyIsUnreadAgain() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        chats.markRead(scout)

        await hub.botSays("Hello again")
        try await chats.reload()

        #expect(chats.isUnread(scout))
    }

    /// Reading here tells the Hub, so the person's other devices show it read.
    @Test func readingHereIsKeptOnTheHub() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        await hub.botSays("Done")
        try await chats.reload()
        let scout = try #require(chats.agents.first)

        chats.markRead(scout)

        let latest = try #require(await hub.messages.last?.createdAt)
        for _ in 0..<50 where await hub.bot.readUpTo != latest { try await Task.sleep(for: .milliseconds(100)) }
        #expect(await hub.bot.readUpTo == latest)
    }

    /// A conversation read on another device is read here too, whether heard at once or on the next sync.
    @Test func aConversationReadElsewhereIsReadHere() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)

        await hub.botSays("Done")
        try await chats.reload()
        #expect(chats.isUnread(scout))
        try await chats.apply(.readChanged(conversationID: scout.conversationID, upTo: try #require(chats.messages(of: scout).last?.createdAt)))
        #expect(!chats.isUnread(scout))

        await hub.botSays("Anything else?")
        try await chats.reload()
        #expect(chats.isUnread(scout))
        let latest = try #require(await hub.messages.last)
        _ = await hub.reply(to: try LinkProtocol.encode(.markRead(LinkReadMark(conversationID: scout.conversationID, messageID: latest.id))))
        try await chats.reload()
        #expect(!chats.isUnread(scout))
    }

    /// Each Hub gets its own topic, the same every time, once the phone listens on it; turned off, both stop.
    @Test func eachHubHearsWhereToLeaveWordOfUnreadReplies() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        let subscriptions = RecordedSubscriptions()
        let notifications = HubNotifications(subscriptions: subscriptions, defaults: UserDefaults(suiteName: UUID().uuidString)!)

        await notifications.register([chats.pairing], allowed: true)
        let topic = PushTopic.topic(for: chats.pairing)
        #expect(await subscriptions.topics == [topic])
        #expect(await hub.pushTopics == [topic])
        #expect(PushTopic.topic(for: HubPairing(directory: chats.pairing.directory, deviceName: "iPhone")) == topic)
        #expect(PushTopic.topic(for: HubPairing(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString), deviceName: "iPhone")) != topic)

        await notifications.register([chats.pairing], allowed: false)
        #expect(await subscriptions.topics.isEmpty)
        #expect(await hub.pushTopics.last == .some(nil))
    }

    /// A Hub the phone left stops notifying it, though its folder, and the topic in it, are gone.
    @Test func aHubLeftStopsNotifying() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        let subscriptions = RecordedSubscriptions()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        await HubNotifications(subscriptions: subscriptions, defaults: defaults).register([chats.pairing], allowed: true)
        #expect(await subscriptions.topics.count == 1)

        try FileManager.default.removeItem(at: chats.pairing.directory)
        await HubNotifications(subscriptions: subscriptions, defaults: defaults).register([], allowed: true)
        #expect(await subscriptions.topics.isEmpty)
    }

    /// Without iCloud nothing could arrive, so the Hub is not asked to leave word.
    @Test func aHubIsGivenNoTopicNobodyListensOn() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        let subscriptions = RecordedSubscriptions()
        await subscriptions.fail()

        await HubNotifications(subscriptions: subscriptions, defaults: UserDefaults(suiteName: UUID().uuidString)!)
            .register([chats.pairing], allowed: true)
        #expect(await hub.pushTopics == [nil])
    }

    /// The phone hears of its own topic only, as a notification it can change before showing, one per conversation.
    @Test func theSubscriptionListensOnTheTopic() {
        let subscription = CloudKitSubscriptions.subscription(topic: "abc")
        #expect(subscription.recordType == LinkPush.recordType)
        #expect(subscription.predicate == NSPredicate(format: "%K == %@", LinkPush.topicField, "abc"))
        #expect(subscription.querySubscriptionOptions == [.firesOnRecordCreation, .firesOnRecordUpdate])
        let info = subscription.notificationInfo
        #expect(Set(info?.desiredKeys ?? []) == [LinkPush.topicField, LinkPush.conversationField, LinkPush.unreadField])
        #expect(info?.collapseIDKey == LinkPush.conversationField)
        #expect(info?.shouldSendMutableContent == true)
        #expect(info?.alertBody?.isEmpty == false)
        #expect(CloudKitSubscriptions.subscription(topic: "xyz").subscriptionID != subscription.subscriptionID)
    }

    @Test func aNotificationLeadsToItsConversation() {
        let conversation = UUID()
        let route = PushTopic.route(fields: [LinkPush.topicField: "abc", LinkPush.conversationField: conversation.uuidString])
        #expect(route == NotificationRoute(topic: "abc", conversation: conversation))
        #expect(PushTopic.route(fields: [LinkPush.topicField: "abc"]) == nil)
    }

    /// A notification names the bot and shows its latest reply, fetched from the Hub whose topic it came under.
    @Test func aNotificationShowsTheBotAndItsReply() async throws {
        let hub = FakeHub()
        await hub.botSays("All done.")
        let hubs = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: hubs.appendingPathComponent(UUID().uuidString))
        defer { server.stop() }
        let conversation = await hub.bot.conversationID

        let route = NotificationRoute(topic: PushTopic.topic(for: chats.pairing), conversation: conversation)
        let reply = await ReplyNotification.content(for: route, hubs: hubs)
        #expect(reply == ReplyNotification.Content(title: "Scout", body: "All done."))
        #expect(await ReplyNotification.content(for: NotificationRoute(topic: "unknown", conversation: conversation), hubs: hubs) == nil)
    }

    @Test func unsentTextIsKeptPerConversation() async throws {
        let hub = FakeHub()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: directory)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)

        chats.setDraft("Half a thought", for: scout)

        #expect(HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone")).draft(for: scout) == "Half a thought")
        chats.setDraft("", for: scout)
        #expect(HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone")).draft(for: scout) == "")
    }

    @Test func longMessagesFoldAtTheMacsLimits() {
        #expect(!MessageFolding.isLong("A short reply."))
        #expect(!MessageFolding.isLong(Array(repeating: "line", count: 12).joined(separator: "\n")))
        #expect(MessageFolding.isLong(Array(repeating: "line", count: 13).joined(separator: "\n")))
        #expect(MessageFolding.isLong(String(repeating: "a", count: 1201)))
    }

    @Test func myReactionReachesTheHubAndComesBack() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        let hello = try #require(chats.messages(of: scout).first)

        try await chats.toggleReaction("👍", on: hello, in: scout)
        #expect(chats.messages(of: scout).first?.reactions == [LinkReaction(author: .you, emoji: "👍")])

        try await chats.toggleReaction("👍", on: try #require(chats.messages(of: scout).first), in: scout)
        #expect(chats.messages(of: scout).first?.reactions == [])
    }

    @Test func pushedChangesUpdateMessagesAndStatus() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        var hello = try #require(chats.messages(of: scout).first)
        hello.reactions = [LinkReaction(author: .bot(scout.id), emoji: "🎉")]

        try await chats.apply(.messageChanged(hello))
        try await chats.apply(.botPhase(botID: scout.id, phase: .working))

        #expect(chats.messages(of: scout).first?.reactions == hello.reactions)
        #expect(chats.agent(scout.id)?.phase == .working)
    }

    /// An admin's Users screen follows the Hub's users, as the Hub pushes that they changed.
    @Test func theHubSayingUsersChangedIsCounted() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        #expect(chats.usersChanges == 0)
        try await chats.apply(.usersChanged)
        try await chats.apply(.usersChanged)
        #expect(chats.usersChanges == 2)
    }

    @Test func aVoiceMessageTravelsWithItsTranscript() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).caf")
        try Data([1, 2, 3]).write(to: audio)
        let voice = LinkVoice(transcript: "Book a table", duration: 2, waveform: [0.2, 0.8], localeIdentifier: "en_GB")

        try await chats.sendVoice(audio, voice: voice, to: scout)

        let sent = try #require(chats.messages(of: scout).first { $0.attachments.first?.voice != nil })
        #expect(sent.body == "Voice message")
        #expect(sent.attachments.first?.voice == voice)
        #expect(sent.attachments.first?.mediaType == "audio/x-caf")
    }

    @Test func typingAtOffersBotsByNameAsOnTheMac() {
        let scout = LinkBot(id: UUID(), conversationID: UUID(), draft: LinkBotDraft(name: "Scout", provider: "codex"), createdAt: Date())
        let atlas = LinkBot(id: UUID(), conversationID: UUID(), draft: LinkBotDraft(name: "Atlas", provider: "codex"), createdAt: Date())
        let sam = LinkBot(id: UUID(), conversationID: UUID(), draft: LinkBotDraft(name: "Sam", provider: "codex"), createdAt: Date())

        let text = "Ask @s"
        let request = try? #require(MentionCompletion.request(in: text, caret: text.utf16.count))
        #expect(request?.query == "s")
        // This conversation's bot first, then by name.
        #expect(request?.matches([atlas, sam, scout], preferred: scout.id).map(\.draft.name) == ["Scout", "Atlas", "Sam"])
        #expect(request?.replacing(with: "Scout", in: text) == "Ask Scout ")

        #expect(MentionCompletion.request(in: "mail@home", caret: 9) == nil)
        #expect(MentionCompletion.request(in: "Hi", caret: 2) == nil)
    }

    /// Backgrounds are the Hub's: the phone shows what is there, fetching a small copy once, and
    /// what it sets goes to the Hub for every device.
    @Test func backgroundsAreKeptOnTheHub() async throws {
        let hub = FakeHub()
        let movie = Data("a small movie".utf8)
        await hub.setBackground(LinkBackground(media: "\(UUID()).mov", mediaKind: "video"), compact: movie)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: directory)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        #expect(chats.background(for: scout).mediaKind == .video)
        let video = try #require(chats.backgroundImageURL(for: scout))
        #expect(video.pathExtension == "mp4")
        #expect(try Data(contentsOf: video) == movie)
        try await chats.reload()
        let relaunched = HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone"))
        #expect(relaunched.backgroundImageURL(for: scout) == video)
        #expect(await hub.backgroundFetches == 1)

        try await chats.setBackground(ConversationBackground(preset: .ocean), for: scout)
        #expect(await hub.bot.background == LinkBackground(preset: "ocean"))
        #expect(chats.background(for: scout).preset == .ocean)
        #expect(chats.backgroundImageURL(for: scout) == nil)
        #expect(!FileManager.default.fileExists(atPath: video.path))

        let photo = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }.pngData()!
        try await chats.setBackground(photo: photo, for: scout)
        let image = try #require(chats.backgroundImageURL(for: scout))
        #expect(chats.background(for: scout).mediaKind == .image)
        #expect(UIImage(contentsOfFile: image.path) != nil)
        #expect(await hub.backgroundUpload == (try Data(contentsOf: image)))
        #expect(await hub.backgroundFetches == 1)

        // Another device takes it away.
        await hub.setBackground(LinkBackground())
        try await chats.apply(.backgroundChanged(conversationID: scout.conversationID, background: LinkBackground()))
        #expect(chats.background(for: scout).isDefault)
        #expect(!FileManager.default.fileExists(atPath: image.path))
    }

    /// Groups made on another device are listed with the bots, with what was said in them.
    @Test func groupsListWithTheirConversations() async throws {
        let hub = FakeHub()
        let group = await hub.addGroup(named: "Crew", saying: "Morning")
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }

        try await chats.reload()

        #expect(chats.groups.map(\.draft.name) == ["Crew"])
        #expect(chats.sortedThreads.map(\.id) == [group.id, await hub.bot.id])
        #expect(chats.latestMessage(of: group)?.body == "Morning")
        #expect(chats.members(of: group).map(\.draft.name) == ["Scout"])
    }

    /// A group made, renamed and deleted from the phone reaches the Hub, and leaves no pin or saved copy behind.
    @Test func aGroupIsMadeEditedAndDeletedOnTheHub() async throws {
        let hub = FakeHub()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: directory)
        defer { server.stop() }
        try await chats.reload()
        let scout = await hub.bot

        var group = try await chats.createGroup(LinkGroupDraft(name: "Crew", botIDs: [scout.id]))
        #expect(await hub.groups.map(\.draft.name) == ["Crew"])
        group.draft.name = "Night Crew"
        try await chats.updateGroup(group)
        #expect(chats.groups.map(\.draft.name) == ["Night Crew"])
        #expect(HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone")).groups.map(\.draft.name) == ["Night Crew"])
        chats.togglePin(group)

        try await chats.deleteGroup(group)

        #expect(chats.groups.isEmpty)
        #expect(await hub.groups.isEmpty)
        let relaunched = HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone"))
        #expect(relaunched.groups.isEmpty)
        #expect(!relaunched.isPinned(group))
    }

    /// A group made on another device shows once the Hub says groups changed.
    @Test func aGroupMadeElsewhereShowsWhenTheHubSaysSo() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let group = await hub.addGroup(named: "Crew", saying: "Morning")

        try await chats.apply(.groupsChanged)

        #expect(chats.groups.map(\.id) == [group.id])
        #expect(chats.latestMessage(of: group)?.body == "Morning")
    }

    /// In a group, a bot's name heads each run of its messages, as in Messages.
    @Test func groupMessagesNameTheirBotAtTheStartOfEachRun() {
        let (scout, atlas, conversation) = (UUID(), UUID(), UUID())
        let messages = [(LinkMessage.Author.bot(scout), 1), (.bot(scout), 2), (.you, 3), (.bot(scout), 4), (.bot(atlas), 5), (.system, 6)]
            .map { LinkMessage(id: UUID(), conversationID: conversation, author: $0.0, body: "\($0.1)",
                               createdAt: Date(timeIntervalSince1970: TimeInterval($0.1)), delivered: true) }
        let names = [scout: "Scout", atlas: "Atlas"]

        let labels = HubChats.authorLabels(in: messages) { names[$0] }

        #expect(messages.compactMap { labels[$0.id] } == ["Scout", "Scout", "Atlas"])
        #expect(labels[messages[1].id] == nil)
    }

    /// In a group, a bot's picture sits beside the last of each run of its messages, as in Messages.
    @Test func groupMessagesShowTheirBotAtTheEndOfEachRun() {
        let (scout, atlas, conversation) = (UUID(), UUID(), UUID())
        let messages = [(LinkMessage.Author.bot(scout), 1), (.bot(scout), 2), (.you, 3), (.bot(scout), 4), (.bot(atlas), 5), (.system, 6)]
            .map { LinkMessage(id: UUID(), conversationID: conversation, author: $0.0, body: "\($0.1)",
                               createdAt: Date(timeIntervalSince1970: TimeInterval($0.1)), delivered: true) }

        let avatars = HubChats.authorAvatars(in: messages)

        #expect(messages.compactMap { avatars[$0.id] } == [scout, scout, atlas])
        #expect(avatars[messages[0].id] == nil)
        #expect(avatars[messages[1].id] == scout)
    }

    @Test func botPicturesAreShrunkAndStoredAsTheMacStoresThem() throws {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 1200), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }()).image { context in
            UIColor.purple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
        }.pngData()!

        let stored = try BotPicture.prepare(big)

        let image = try #require(UIImage(data: stored)?.cgImage)
        #expect(max(image.width, image.height) == 512)
        #expect(stored.starts(with: [0xFF, 0xD8]))
    }

    /// A send that fails is tried again by itself while nothing newer has come, and arrives once.
    @Test func aFailedSendIsTriedAgainWhileItIsTheNewest() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = await hub.bot
        chats.retryPauses = [.zero, .zero, .zero]
        await hub.failSends(2)

        try await chats.send("Hi", to: scout)

        let sent = try #require(chats.messages(of: scout).first { $0.body == "Hi" })
        #expect(chats.delivery(of: sent) == "Delivered")
        #expect(await hub.bodies(saying: "Hi") == 1)
    }

    /// When it keeps failing, the message itself says so, rather than an error under the conversation,
    /// and still does after the app is opened again.
    @Test func aSendThatKeepsFailingIsMarkedOnTheMessage() async throws {
        let hub = FakeHub()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: directory)
        defer { server.stop() }
        try await chats.reload()
        let scout = await hub.bot
        chats.retryPauses = [.zero, .zero]
        await hub.failSends(10)

        try await chats.send("Hi", to: scout)

        let sent = try #require(chats.messages(of: scout).last)
        #expect(sent.body == "Hi")
        #expect(chats.delivery(of: sent) == "Not delivered")
        #expect(chats.unsentReason(of: sent) == "The Hub did not answer in time.")
        let relaunched = HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone"))
        #expect(relaunched.messages(of: scout).last?.id == sent.id)
        #expect(relaunched.delivery(of: sent) == "Not delivered")
    }

    /// Once the conversation has moved on, a failed message is never sent by itself: out of its place it
    /// may no longer make sense. Still the newest, it goes when the Hub answers again.
    @Test func aFailedMessageIsSentAgainOnlyWhileItIsTheNewest() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = await hub.bot
        chats.retryPauses = [.zero]
        await hub.failSends(10)
        try await chats.send("First", to: scout)
        try await chats.send("Second", to: scout)
        await hub.failSends(0)

        try await chats.reload()

        let messages = chats.messages(of: scout)
        let first = try #require(messages.first { $0.body == "First" })
        let second = try #require(messages.first { $0.body == "Second" })
        #expect(await hub.bodies(saying: "First") == 0)
        #expect(chats.delivery(of: first) == "Not delivered")
        #expect(!chats.canTryAgain(first))
        #expect(await hub.bodies(saying: "Second") == 1)
        #expect(chats.delivery(of: second) == "Delivered")
    }

    /// The Hub may have taken a message whose answer was lost; its copy settles it, with no second one.
    @Test func aMessageTheHubGotDespiteTheFailureIsNotSentTwice() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = await hub.bot
        chats.retryPauses = [.zero]
        await hub.failSends(1, keeping: true)
        try await chats.send("Hi", to: scout)

        try await chats.reload()

        let sent = try #require(chats.messages(of: scout).first { $0.body == "Hi" })
        #expect(chats.delivery(of: sent) == "Delivered")
        #expect(chats.unsentReason(of: sent) == nil)
        #expect(await hub.bodies(saying: "Hi") == 1)
    }

    /// Edit and Send puts a failed message's text and files back to send anew; Delete drops it.
    @Test func aFailedMessageCanBeTakenBackOrDeleted() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = await hub.bot
        chats.retryPauses = [.zero]
        await hub.failSends(10)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("notes".utf8).write(to: file)
        try await chats.send("Look", files: [OutgoingFile(url: file, filename: "notes.txt", mediaType: "text/plain")], to: scout)
        try await chats.send("Hi", to: scout)
        let look = try #require(chats.messages(of: scout).first { $0.body == "Look" })
        let hi = try #require(chats.messages(of: scout).first { $0.body == "Hi" })

        let (text, files) = try chats.takeBack(look, in: scout)
        chats.delete(hi, in: scout)

        #expect(text == "Look")
        #expect(files.map(\.filename) == ["notes.txt"])
        #expect(try Data(contentsOf: try #require(files.first).url) == Data("notes".utf8))
        #expect(!chats.messages(of: scout).contains { $0.id == look.id || $0.id == hi.id })
    }

    /// A longer message grows the field over the conversation, as in Messages; the conversation keeps
    /// its place and its gap at the end.
    @Test func typingMoreLinesLeavesTheConversationWhereItIs() async throws {
        let hub = FakeHub()
        for index in 1..<40 { await hub.botSays(String(repeating: "Message \(index) says something. ", count: 1 + index % 4)) }
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)

        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack { ChatView(chats: chats, threadID: scout.id) })
        window.isHidden = false
        defer { window.isHidden = true }
        try await Task.sleep(for: .seconds(1))

        let conversation = try #require(Self.view(UIScrollView.self, in: window) { !($0 is UITextView) && $0.contentSize.height > window.bounds.height })
        let field = try #require(Self.view(PastingTextView.self, in: window) { _ in true })
        field.becomeFirstResponder()
        field.insertText("Hello")
        try await Task.sleep(for: .milliseconds(300))
        let (offset, gap, height) = (conversation.contentOffset.y, conversation.adjustedContentInset.bottom, field.bounds.height)

        field.insertText("\n\n\n")
        try await Task.sleep(for: .milliseconds(300))

        #expect(field.bounds.height > height)
        #expect(conversation.adjustedContentInset.bottom == gap)
        #expect(conversation.contentOffset.y == offset)
    }

    /// The message field sits as low as the bots list's search field, and the conversation still ends
    /// 16 points above it.
    @Test func theComposerSitsAsLowAsSearch() async throws {
        let hub = FakeHub()
        for index in 1..<40 { await hub.botSays(String(repeating: "Message \(index) says something. ", count: 1 + index % 4)) }
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)

        let list = UIWindow(windowScene: scene)
        list.rootViewController = UIHostingController(rootView: NavigationStack {
            List { Text("Bot") }.listStyle(.plain).searchable(text: .constant(""), prompt: "Search")
        })
        list.isHidden = false
        try await Task.sleep(for: .seconds(1))
        let search = try #require(Self.view(UISearchTextField.self, in: list) { _ in true })
        let capsule = try #require(sequence(first: search as UIView, next: \.superview).first { $0.bounds.height > search.bounds.height })
        let searchBottom = capsule.convert(capsule.bounds, to: list).maxY
        list.isHidden = true

        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack { ChatView(chats: chats, threadID: scout.id) })
        window.isHidden = false
        defer { window.isHidden = true }
        try await Task.sleep(for: .seconds(1))
        let conversation = try #require(Self.view(UIScrollView.self, in: window) { !($0 is UITextView) && $0.contentSize.height > window.bounds.height })
        let field = try #require(Self.view(PastingTextView.self, in: window) { _ in true })
        // The text sits 13 points inside the glass around it.
        let fieldBottom = field.convert(field.bounds, to: window).maxY + 13
        let end = conversation.convert(conversation.bounds, to: window).maxY - conversation.adjustedContentInset.bottom

        #expect(abs(fieldBottom - searchBottom) < 1)
        #expect(abs(fieldBottom - ChatView.controlHeight - end - 16) < 1)
    }

    /// Left at its end and opened again, a conversation shows its end again.
    @Test func aConversationLeftAtItsEndReopensThere() async throws {
        let hub = FakeHub()
        for index in 1..<30 {
            let points = (1...(2 + index % 14)).map { "• Point \($0) of reply \(index), which runs long enough to wrap over more than one line." }
            await hub.botSays("Reply \(index):\n\n" + points.joined(separator: "\n"))
            await hub.botSays(String(repeating: "Message \(index) says something. ", count: 1 + index % 4))
        }
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)

        let path = OpenChats()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ReopenedChat(chats: chats, path: path))
        window.isHidden = false
        defer { window.isHidden = true }
        func conversation() throws -> UIScrollView {
            try #require(Self.view(UIScrollView.self, in: window) { !($0 is UITextView) && $0.contentSize.height > window.bounds.height })
        }
        func end(of view: UIScrollView) -> CGFloat { view.contentSize.height + view.adjustedContentInset.bottom - view.bounds.height }

        path.threads = [scout.id]
        try await Task.sleep(for: .seconds(1))
        // Scrolled up and back down to the end, as a person reading does.
        let opened = try conversation()
        opened.setContentOffset(CGPoint(x: opened.contentOffset.x, y: opened.contentOffset.y - 2000), animated: false)
        try await Task.sleep(for: .milliseconds(300))
        for _ in 0..<5 {
            opened.setContentOffset(CGPoint(x: opened.contentOffset.x, y: end(of: opened)), animated: false)
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(abs(opened.contentOffset.y - end(of: opened)) <= 1)

        path.threads = []
        try await Task.sleep(for: .seconds(1))
        path.threads = [scout.id]
        try await Task.sleep(for: .seconds(1))

        let reopened = try conversation()
        #expect(abs(reopened.contentOffset.y - end(of: reopened)) <= 1)
    }

    /// With the keyboard up, the message field keeps 8 points clear of it, and the conversation still
    /// ends 16 points above the field.
    @Test func theComposerSitsClearOfTheKeyboard() async throws {
        let hub = FakeHub()
        for index in 1..<40 { await hub.botSays(String(repeating: "Message \(index) says something. ", count: 1 + index % 4)) }
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)

        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack { ChatView(chats: chats, threadID: scout.id) })
        window.isHidden = false
        defer { window.isHidden = true }
        try await Task.sleep(for: .seconds(1))
        let field = try #require(Self.view(PastingTextView.self, in: window) { _ in true })
        // The simulator shows no keyboard, and SwiftUI does not make room for a posted notice of one,
        // so the field is measured from the edge the keyboard would take: the safe area's.
        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        try await Task.sleep(for: .milliseconds(500))

        let keyboardTop = window.bounds.maxY - window.safeAreaInsets.bottom
        let conversation = try #require(Self.view(UIScrollView.self, in: window) { !($0 is UITextView) && $0.contentSize.height > window.bounds.height })
        // The text sits 13 points inside the glass around it.
        let fieldBottom = field.convert(field.bounds, to: window).maxY + 13
        let end = conversation.convert(conversation.bounds, to: window).maxY - conversation.adjustedContentInset.bottom

        #expect(abs(keyboardTop - fieldBottom - 8) < 1)
        #expect(abs(fieldBottom - ChatView.controlHeight - end - 16) < 1)
    }

    private static func view<V: UIView>(_ type: V.Type, in view: UIView, where test: (V) -> Bool) -> V? {
        if let match = view as? V, test(match) { return match }
        for subview in view.subviews { if let match = self.view(type, in: subview, where: test) { return match } }
        return nil
    }
}

@MainActor @Observable final class OpenChats {
    var threads: [UUID] = []
}

/// A list a conversation is opened from and left for, as the bots list does.
private struct ReopenedChat: View {
    let chats: HubChats
    @Bindable var path: OpenChats

    var body: some View {
        NavigationStack(path: $path.threads) {
            List { Text("Bots") }
                .navigationDestination(for: UUID.self) { ChatView(chats: chats, threadID: $0) }
        }
    }
}
