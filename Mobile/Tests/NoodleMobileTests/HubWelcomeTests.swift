import Foundation
import HubLink
import NoodleBrand
@testable import NoodleMobile
import Testing

/// A Hub that lends `harnesses` and keeps the bots, groups and messages the phone makes, reached over QUIC.
private actor WelcomeHub {
    let harnesses: [LinkHarness]
    var bots: [LinkBot]
    var groups: [LinkGroup] = []
    var messages: [LinkMessage] = []
    /// Bots made before one creation is answered with a failure, once; nil fails none.
    var failsAfter: Int?
    /// Where it listens, which it tells the phone when pairing, as the real Hub does.
    var endpoints: [LinkEndpoint] = []

    init(harnesses: [LinkHarness], bots: [LinkBot] = []) {
        self.harnesses = harnesses
        self.bots = bots
    }

    func failOnce(after count: Int) { failsAfter = count }
    func listen(at endpoint: LinkEndpoint) { endpoints = [endpoint] }

    func reply(to data: Data) -> LinkResponse {
        switch LinkProtocol.decode(data) {
        case .success(.enroll):
            return .status(LinkStatus(hubName: "Studio", userName: "Petko", planName: "", harnesses: harnesses, endpoints: endpoints))
        case .success(.bots):
            return .bots(bots)
        case .success(.groups):
            return .groups(groups)
        case .success(.createBot) where failsAfter == bots.count:
            failsAfter = nil
            return .failure("The Hub did not answer in time.")
        case .success(.createBot(let draft)):
            let bot = LinkBot(id: UUID(), conversationID: UUID(), draft: draft, createdAt: Date())
            bots.append(bot)
            return .bot(bot)
        case .success(.createGroup(let draft)):
            let group = LinkGroup(id: UUID(), draft: draft, createdAt: Date())
            groups.append(group)
            return .group(group)
        case .success(.messages(let conversationID, let after)):
            let found = messages.filter { $0.conversationID == conversationID }
            return .messages(LinkMessages(messages: Array(found.dropFirst(after)), count: found.count))
        case .success(.messagePage(let page)):
            let found = messages.filter { $0.conversationID == page.conversationID }
            return .messages(LinkMessages(messages: Array(found.suffix(page.limit)), count: found.count,
                                          start: max(0, found.count - page.limit)))
        case .success(.send(let outgoing)):
            let sent = LinkMessage(id: outgoing.id, conversationID: outgoing.conversationID, author: .you, body: outgoing.body,
                                   createdAt: Date(), delivered: true)
            messages.append(sent)
            return .message(sent)
        default:
            return .failure("Not in this test.")
        }
    }
}

@MainActor @Suite struct HubWelcomeTests {
    private static let codex = LinkHarness(provider: "codex", providerName: "Codex", profile: UUID(), profileName: "Work",
                                           models: [LinkModel(id: "gpt-5", name: "GPT-5")], restrictsModels: true)

    private func joined(_ hub: WelcomeHub) async throws -> (HubWelcome, LinkServer) {
        let identity = LinkIdentity()
        let server = try LinkServer(identity: identity, port: 0, admits: { _ in true }) { _, data in
            .response(LinkProtocol.encode(await hub.reply(to: data)))
        }
        try await server.start()
        let endpoint = LinkEndpoint(host: "127.0.0.1", port: try #require(server.port))
        await hub.listen(at: endpoint)
        let invitation = LinkInvitation(hubName: "Studio", hubKey: identity.publicKey, endpoints: [endpoint], userName: "Petko",
                                        joinKey: LinkIdentity().privateKey.rawRepresentation, expires: Date().addingTimeInterval(600))
        let pairing = HubPairing(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                 deviceName: "iPhone")
        await pairing.join(invitation.url().absoluteString)
        try #require(pairing.hub != nil)
        return (HubWelcome(pairing: pairing), server)
    }

    @Test func theFirstHubGetsTheTeamAndTheirGroupOnTheHarnessItLends() async throws {
        let hub = WelcomeHub(harnesses: [Self.codex, LinkHarness(provider: "apple", providerName: "Apple Intelligence", profileName: nil)])
        let (welcome, server) = try await joined(hub)
        defer { server.stop() }

        await welcome.make()

        #expect(welcome.stage == .ready)
        let bots = await hub.bots
        #expect(bots.map(\.id) == welcome.team.map(\.id))
        #expect(bots.map(\.draft.backstory) == StarterTeam.members.map(\.backstory))
        #expect(bots.map(\.draft.publicDescription) == StarterTeam.members.map(\.publicDescription))
        #expect(bots.map(\.draft.avatarSymbolName) == StarterTeam.members.map(\.symbol))
        #expect(bots.map(\.draft.avatarColorIndex) == StarterTeam.members.map(\.colorIndex))
        #expect(Set(bots.map(\.draft.name)).count == 3, "Each has a name of its own.")
        for bot in bots {
            #expect(bot.draft.provider == "codex")
            #expect(bot.draft.profile == Self.codex.profile)
            #expect(bot.draft.model == "gpt-5", "A plan that leaves no harness default gets its first model.")
        }
        let group = try #require(await hub.groups.first)
        #expect(group.draft.name == StarterTeam.groupName)
        #expect(group.draft.publicDescription == StarterTeam.groupDescription)
        #expect(group.draft.botIDs == bots.map(\.id))
        #expect(welcome.group?.id == group.id)
    }

    @Test func continuingGreetsTheTeamInTheirGroup() async throws {
        let hub = WelcomeHub(harnesses: [Self.codex])
        let (welcome, server) = try await joined(hub)
        defer { server.stop() }
        await welcome.make()

        await welcome.greet()

        let group = try #require(welcome.group)
        let sent = await hub.messages
        #expect(sent.map(\.body) == [StarterTeam.greeting])
        #expect(sent.map(\.conversationID) == [group.id])
        #expect(welcome.chats.groups.map(\.id) == [group.id], "The list opens on it at once.")
    }

    @Test func someoneWithBotsOnTheHubGetsNoTeam() async throws {
        let mine = LinkBot(id: UUID(), conversationID: UUID(), draft: LinkBotDraft(name: "Scout", provider: "codex"), createdAt: Date())
        let hub = WelcomeHub(harnesses: [Self.codex], bots: [mine])
        let (welcome, server) = try await joined(hub)
        defer { server.stop() }

        await welcome.make()

        #expect(welcome.stage == .skipped)
        #expect(await hub.bots.map(\.id) == [mine.id])
        #expect(await hub.groups.isEmpty)
    }

    @Test func aPlanLendingNoHarnessSaysSo() async throws {
        let hub = WelcomeHub(harnesses: [])
        let (welcome, server) = try await joined(hub)
        defer { server.stop() }

        await welcome.make()

        guard case .failed(let message) = welcome.stage else { Issue.record("\(welcome.stage)"); return }
        #expect(message.contains("lends no harnesses"))
        #expect(await hub.bots.isEmpty)
    }

    @Test func tryingAgainFinishesTheTeamWithoutMakingAnyTwice() async throws {
        let hub = WelcomeHub(harnesses: [Self.codex])
        let (welcome, server) = try await joined(hub)
        defer { server.stop() }
        // The second bot fails, as when the Hub is slow to answer.
        await hub.failOnce(after: 1)
        await welcome.make()
        guard case .failed = welcome.stage else { Issue.record("\(welcome.stage)"); return }
        #expect(welcome.team.count == 1)

        await welcome.make()

        #expect(welcome.stage == .ready)
        let bots = await hub.bots
        #expect(bots.map(\.id) == welcome.team.map(\.id))
        #expect(bots.map(\.draft.backstory) == StarterTeam.members.map(\.backstory))
        #expect(Set(bots.map(\.draft.name)).count == 3)
        #expect(await hub.groups.map(\.draft.botIDs) == [bots.map(\.id)])
    }
}
