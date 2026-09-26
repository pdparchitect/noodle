import Foundation
import HubLink
import NoodleWallpaperCore
import UIKit
@testable import NoodleMobile
import Testing

/// A Hub with one bot that answers every message, reached over QUIC like the real one.
private actor FakeHub {
    var bot = LinkBot(id: UUID(), conversationID: UUID(),
                      draft: LinkBotDraft(name: "Scout", provider: "claude"), createdAt: Date(timeIntervalSince1970: 0))
    var created: [LinkBot] = []
    /// Files by ID, as uploaded or given to the bot's messages.
    var files: [UUID: (attachment: LinkAttachment, data: Data)] = [:]
    var downloads = 0
    var messages: [LinkMessage] = []
    /// Where it listens, which it tells the phone when pairing, as the real Hub does.
    var endpoints: [LinkEndpoint] = []

    func listen(at endpoint: LinkEndpoint) { endpoints = [endpoint] }

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
            return .bots([bot] + created)
        case .success(.updateBot(let id, let draft)) where id == bot.id:
            bot.draft = draft
            return .bot(bot)
        case .success(.deleteBot(let id)):
            created.removeAll { $0.id == id }
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
        case .success(.send(let outgoing)):
            let attachments = outgoing.attachmentIDs.compactMap { files[$0]?.attachment }
            guard attachments.count == outgoing.attachmentIDs.count else { return .failure("A file is missing.") }
            let sent = LinkMessage(id: outgoing.id, conversationID: bot.conversationID, author: .you, body: outgoing.body,
                                   createdAt: Date(), delivered: true, attachments: attachments)
            messages.append(sent)
            messages.append(LinkMessage(id: UUID(), conversationID: bot.conversationID, author: .bot(bot.id),
                                        body: "You said: \(outgoing.body)", createdAt: Date(), delivered: true))
            return .message(sent)
        default:
            return .failure("Not in this test.")
        }
    }
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
                                        userName: "Petko", token: "t", expires: Date().addingTimeInterval(600))
        let pairing = HubPairing(directory: directory, deviceName: "iPhone")
        await pairing.join(invitation.url().absoluteString)
        try #require(pairing.hub != nil)
        return (HubChats(pairing: pairing), server)
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
        #expect(chats.sortedAgents.map(\.id) == [atlas.id, scout.id])

        chats.togglePin(scout)

        #expect(chats.isPinned(scout))
        #expect(chats.sortedAgents.map(\.id) == [scout.id, atlas.id])
        let relaunched = HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone"))
        #expect(relaunched.isPinned(scout))
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

    @Test func eachConversationKeepsItsOwnBackground() async throws {
        let hub = FakeHub()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: directory)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        #expect(chats.background(for: scout).isDefault)

        try chats.setBackground(ConversationBackground(preset: .ocean), for: scout)
        #expect(HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone")).background(for: scout).preset == .ocean)

        let photo = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }.jpegData(compressionQuality: 0.9)!
        try chats.setBackground(photo: photo, for: scout)
        let relaunched = HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone"))
        let image = try #require(relaunched.backgroundImageURL(for: scout))
        #expect(relaunched.background(for: scout).imageFilename != nil)
        #expect(FileManager.default.fileExists(atPath: image.path))

        try chats.setBackground(ConversationBackground(), for: scout)
        #expect(chats.background(for: scout).isDefault)
        #expect(!FileManager.default.fileExists(atPath: image.path))
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
}
