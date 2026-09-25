import Foundation
import HubLink
@testable import NoodleMobile
import Testing

/// A Hub with one bot that answers every message, reached over QUIC like the real one.
private actor FakeHub {
    var bot = LinkBot(id: UUID(), conversationID: UUID(),
                      draft: LinkBotDraft(name: "Scout", provider: "claude"), createdAt: Date(timeIntervalSince1970: 0))
    var created: [LinkBot] = []
    var messages: [LinkMessage] = []
    /// Where it listens, which it tells the phone when pairing, as the real Hub does.
    var endpoints: [LinkEndpoint] = []

    func listen(at endpoint: LinkEndpoint) { endpoints = [endpoint] }

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
        case .success(.createBot(let draft)):
            let new = LinkBot(id: UUID(), conversationID: UUID(), draft: draft, createdAt: Date())
            created.append(new)
            return .bot(new)
        case .success(.messages(let conversationID, let after)):
            let messages = messages.filter { $0.conversationID == conversationID }
            return .messages(LinkMessages(messages: Array(messages.dropFirst(after)), count: messages.count))
        case .success(.send(let outgoing)):
            let sent = LinkMessage(id: outgoing.id, conversationID: bot.conversationID, author: .you, body: outgoing.body,
                                   createdAt: Date(), delivered: true)
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
}
