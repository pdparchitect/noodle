import Foundation
import HubLink
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
        let server = try LinkServer(identity: identity, port: 0) { _, data in
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
}
