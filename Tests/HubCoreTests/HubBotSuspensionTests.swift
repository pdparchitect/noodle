import Foundation
import HubCore
import HubLink
import NoodleCore
import NoodleRuntime
import XCTest

/// A bot suspended on the Hub stays listed but takes no new turn until its time runs out or it is unsuspended.
@MainActor final class HubBotSuspensionTests: XCTestCase {
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-bot-suspension-\(UUID())")
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

    func testASuspendedBotFinishesItsTurnStaysListedAndContinuesWhenUnsuspended() async throws {
        let f = try fixture()
        f.runtime.start(agent: f.kai, repository: f.hub.repository)
        let turn = try XCTUnwrap(f.processes().last)
        turn.set(.working)

        let until = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 3600).rounded(.down))
        try f.hub.bots.setSuspended(until: until, id: f.kai.id, for: f.ada)
        XCTAssertEqual(turn.stops, 0, "The turn under way goes on")
        turn.set(.ready)
        XCTAssertEqual(turn.stops, 1)
        XCTAssertTrue(f.runtime.snapshot(for: f.kai.id).detail.hasPrefix("Suspended until"))

        // Listed, not archived, saying until when; Organize is refused, messages still go through.
        let listed = try XCTUnwrap(f.hub.bots.bots(for: f.ada).first { $0.id == f.kai.id })
        XCTAssertNil(listed.archivedAt)
        XCTAssertEqual(listed.suspendedUntil, until)
        XCTAssertEqual(listed.pause?.until, until)
        XCTAssertTrue(listed.pause?.summary.hasPrefix("Suspended until") == true, listed.pause?.summary ?? "")
        XCTAssertThrowsError(try f.hub.bots.organize(f.kai.id, for: f.ada))
        _ = try f.hub.bots.send("Hello", id: UUID(), in: f.conversation, for: f.ada)
        f.runtime.reconcile(agents: try f.hub.repository.loadAgents(), repository: f.hub.repository, immediately: true)
        XCTAssertEqual(f.processes().count, 1, "No new turn starts while it is suspended")

        try f.hub.bots.setSuspended(until: nil, id: f.kai.id, for: f.ada)
        XCTAssertNil(f.runtime.heldAgents[f.kai.id])
        XCTAssertEqual(f.processes().count, 2)
        let resumed = try XCTUnwrap(f.processes().last)
        await waitUntil { resumed.notifications > 0 }
        XCTAssertNil(try XCTUnwrap(f.hub.bots.bots(for: f.ada).first { $0.id == f.kai.id }).suspendedUntil)
    }

    func testOnlyItsOwnerCanSuspendABot() throws {
        let f = try fixture()
        let grace = try f.hub.access.addUser(named: "Grace")
        XCTAssertThrowsError(try f.hub.bots.setSuspended(until: AgentRecord.indefinitely, id: f.kai.id, for: grace))
        XCTAssertNil(try f.hub.repository.loadAgents().first { $0.id == f.kai.id }?.suspendedUntil)
    }

    func testASuspensionThatRanOutNoLongerHoldsTheBot() throws {
        let f = try fixture()
        try f.hub.repository.setAgentSuspended(until: Date().addingTimeInterval(-1), agentID: f.kai.id)
        f.hub.bots.applySuspensions(try f.hub.repository.loadAgents())
        XCTAssertNil(f.runtime.heldAgents[f.kai.id])
        XCTAssertNil(try XCTUnwrap(f.hub.bots.bots(for: f.ada).first { $0.id == f.kai.id }).suspendedUntil)
    }

    /// A suspension and a plan's token limit each hold the bot; letting go of one leaves the other.
    func testHoldsForDifferentReasonsStack() throws {
        let f = try fixture()
        f.runtime.hold([f.kai.id: "Token limit reached."], for: .planLimit)
        try f.hub.bots.setSuspended(until: AgentRecord.indefinitely, id: f.kai.id, for: f.ada)
        XCTAssertEqual(f.runtime.heldAgents[f.kai.id], "Suspended")
        try f.hub.bots.setSuspended(until: nil, id: f.kai.id, for: f.ada)
        XCTAssertEqual(f.runtime.heldAgents[f.kai.id], "Token limit reached.")
    }

    func testTheRequestRoundTripsAndTheHubSaysItSuspends() throws {
        let until = Date(timeIntervalSince1970: 1_900_000_000)
        let data = try LinkProtocol.encode(.suspend(LinkSuspension(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, until: until)))
        guard case .success(.suspend(let change)) = LinkProtocol.decode(data) else { return XCTFail("Not a suspension") }
        XCTAssertEqual(change.until, until)
        // A bot from a Hub before suspensions decodes as not suspended.
        let old = Data(#"{"id":"00000000-0000-0000-0000-000000000002","conversationID":"00000000-0000-0000-0000-000000000003","draft":{"name":"Kai","provider":"codex"},"createdAt":0}"#.utf8)
        let decoder = JSONDecoder()
        XCTAssertNil(try? decoder.decode(LinkBot.self, from: old).suspendedUntil)
    }

    func testChoicesWorkOutWhenTheBotContinuesOnTheDevice() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 22, minute: 30)))
        XCTAssertEqual(LinkSuspensionChoice.hour.until(from: now, calendar: calendar), now.addingTimeInterval(3600))
        XCTAssertEqual(LinkSuspensionChoice.tomorrow.until(from: now, calendar: calendar),
                       calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 9)))
        XCTAssertEqual(LinkSuspensionChoice.indefinitely.until(from: now, calendar: calendar), AgentRecord.indefinitely)
        XCTAssertEqual(AgentRecord.suspension(until: AgentRecord.indefinitely), "Suspended")
    }
}
