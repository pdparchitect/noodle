import Foundation
import HubCore
import HubLink
import HubMac
import NoodleCore
import NoodleRuntime
import XCTest

/// Stop from a device ends a Hub bot's turn, keeps its session and says so in its conversation.
@MainActor final class HubBotStopTests: XCTestCase {
    private struct Fixture {
        let hub: Hub
        let runtime: AgentRuntimeCoordinator
        let processes: () -> [FakeProcess]
        let ada: HubUser
        let kai: AgentRecord
        let conversation: UUID
    }

    private func fixture() throws -> Fixture {
        let (runtime, processes) = try fakeRuntime()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-bot-stop-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(root: root, messenger: nil, runtime: runtime)
        try hub.repository.prepare()
        let plan = try hub.access.addPlan(named: "Family")
        hub.access.set(HubHarness(provider: .codex, profile: nil), included: true, in: plan)
        let ada = try hub.access.addUser(named: "Ada")
        hub.access.move(ada, to: plan)
        hub.bots.watch()
        addTeardownBlock { await MainActor.run { hub.bots.stopWatching() } }
        let bot = try hub.bots.create(LinkBotDraft(name: "Kai", provider: "codex"), for: ada)
        let kai = try XCTUnwrap(hub.repository.loadAgents().first { $0.id == bot.id })
        return Fixture(hub: hub, runtime: runtime, processes: processes, ada: ada, kai: kai, conversation: bot.conversationID)
    }

    func testItsOwnerStopsAWorkingBotAndItsConversationSaysSo() throws {
        let f = try fixture()
        f.runtime.start(agent: f.kai, repository: f.hub.repository)
        let turn = try XCTUnwrap(f.processes().last)
        XCTAssertThrowsError(try f.hub.bots.stop(f.kai.id, for: f.ada), "Only a working bot can be stopped")
        turn.set(.working)

        try f.hub.bots.stop(f.kai.id, for: f.ada)
        XCTAssertEqual(turn.stops, 1, "A harness that cannot cancel its turn restarts")
        XCTAssertEqual(f.processes().count, 2)
        XCTAssertEqual(f.runtime.snapshot(for: f.kai.id).phase, .ready)
        let note = try XCTUnwrap(f.hub.repository.loadMessages(conversationID: f.conversation).last)
        XCTAssertEqual(note.author, .system)
        XCTAssertEqual(note.body, "You stopped Kai.")
    }

    func testNobodyElseCanStopABot() throws {
        let f = try fixture()
        f.runtime.start(agent: f.kai, repository: f.hub.repository)
        let turn = try XCTUnwrap(f.processes().last)
        turn.set(.working)
        let grace = try f.hub.access.addUser(named: "Grace")
        XCTAssertThrowsError(try f.hub.bots.stop(f.kai.id, for: grace))
        XCTAssertEqual(turn.stops, 0)
        XCTAssertEqual(f.runtime.snapshot(for: f.kai.id).phase, .working)
        XCTAssertNil(try f.hub.repository.loadMessages(conversationID: f.conversation).last { $0.author == .system })
    }

    /// Whoever keeps the Hub stops it from Settings › Bots, for its owner.
    func testTheHubsKeeperStopsABotForItsOwner() throws {
        let f = try fixture()
        f.runtime.start(agent: f.kai, repository: f.hub.repository)
        try XCTUnwrap(f.processes().last).set(.working)
        try f.hub.bots.stop(f.kai.id)
        XCTAssertEqual(f.processes().count, 2)
    }

    func testTheRequestRoundTripsAndOnlyAHubThatSaysSoIsAsked() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let data = try LinkProtocol.encode(.stop(botID: id))
        guard case .success(.stop(let botID)) = LinkProtocol.decode(data) else { return XCTFail("Not a stop") }
        XCTAssertEqual(botID, id)
        // A Hub from before Stop does not say it stops bots, so devices do not offer it.
        let old = try JSONDecoder().decode(LinkStatus.self, from: Data(#"{"hubName":"Hub"}"#.utf8))
        XCTAssertFalse(old.stopsBots)
    }
}
