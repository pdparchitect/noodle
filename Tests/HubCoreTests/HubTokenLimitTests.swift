import Foundation
import HubCore
import HubLink
import HubMac
import NoodleCore
import NoodleRuntime
import XCTest

/// A plan's token limit holds its users' bots once they used it up, until the tokens are older than its period.
@MainActor final class HubTokenLimitTests: XCTestCase {
    private struct Fixture {
        let hub: Hub
        let runtime: AgentRuntimeCoordinator
        let processes: () -> [FakeProcess]
        let plan: HubPlan
        let ada: HubUser
        let kai: AgentRecord
        let conversation: UUID
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture() throws -> Fixture {
        let (runtime, processes) = try fakeRuntime()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-tokens-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(root: root, messenger: nil, runtime: runtime)
        try hub.repository.prepare()
        hub.tokenLimits.now = { [unowned self] in self.now }
        let plan = try hub.access.addPlan(named: "Family")
        hub.access.set(HubHarness(provider: .codex, profile: nil), included: true, in: plan)
        let ada = try hub.access.addUser(named: "Ada")
        hub.access.move(ada, to: plan)
        hub.bots.watch()
        addTeardownBlock { await MainActor.run { hub.bots.stopWatching() } }
        let bot = try hub.bots.create(LinkBotDraft(name: "Kai", provider: "codex"), for: ada)
        let kai = try XCTUnwrap(hub.repository.loadAgents().first { $0.id == bot.id })
        return Fixture(hub: hub, runtime: runtime, processes: processes, plan: plan, ada: ada, kai: kai,
                       conversation: bot.conversationID)
    }

    /// What the runtime reports for one model call of Kai's.
    private func use(_ f: Fixture, input: Int, cacheRead: Int = 0, at seconds: TimeInterval) {
        f.runtime.onUsage?(UsageSample(date: start.addingTimeInterval(seconds), agentID: f.kai.id, agentName: "Kai",
                                       harness: "codex", model: "gpt-5", tokens: UsageTokens(input: input, cacheRead: cacheRead),
                                       costUSD: nil))
    }

    private func send(_ f: Fixture, _ body: String) throws {
        _ = try f.hub.bots.send(body, id: UUID(), in: f.conversation, for: f.ada)
    }

    func testABotFinishesItsTurnThenWaitsUntilItsOwnersTokensLeaveThePeriod() async throws {
        let f = try fixture()
        f.hub.access.setTokenLimit(HubTokenLimit(tokens: 1_000, length: 1, unit: .days), in: f.plan)
        f.runtime.start(agent: f.kai, repository: f.hub.repository)
        let turn = try XCTUnwrap(f.processes().last)
        turn.set(.working)

        // Cache reads repeat input already counted, so they do not count again.
        use(f, input: 900, cacheRead: 50_000, at: 0)
        XCTAssertNil(f.hub.tokenLimits.holds[f.ada.id])
        XCTAssertEqual(f.hub.tokenLimits.used(by: f.ada)?.tokens, 900)
        now = start.addingTimeInterval(3600)
        use(f, input: 100, at: 3600)
        // The 900 tokens leave the day a day after they were used, leaving 100.
        XCTAssertEqual(f.hub.tokenLimits.holds[f.ada.id], start.addingTimeInterval(86_400))

        // The turn under way goes on.
        XCTAssertEqual(turn.stops, 0)
        XCTAssertEqual(f.runtime.snapshot(for: f.kai.id).phase, .working)

        // Once it ends, the bot stops before taking another, shown as stopped rather than failed.
        turn.set(.ready)
        XCTAssertEqual(turn.stops, 1)
        let held = f.runtime.snapshot(for: f.kai.id)
        XCTAssertEqual(held.phase, .offline)
        XCTAssertNil(held.failure)
        XCTAssertEqual(f.hub.bots.phase(of: f.kai), .offline)
        XCTAssertTrue(held.detail.hasPrefix("Token limit reached."), held.detail)

        // A message still goes through and waits for the bot; nothing starts it meanwhile.
        try send(f, "Hello")
        XCTAssertEqual(try f.hub.repository.loadMessages(conversationID: f.conversation).filter { $0.author == .user }.map(\.body), ["Hello"])
        f.runtime.reconcile(agents: [f.kai], repository: f.hub.repository, immediately: true)
        f.runtime.refresh(agents: [f.kai], repository: f.hub.repository)
        XCTAssertEqual(f.processes().count, 1, "No new turn starts while it waits")
        XCTAssertEqual(f.runtime.snapshot(for: f.kai.id).detail, held.detail)

        // A day after the first tokens, the rest are under the limit; the bot starts again and reads the message.
        now = start.addingTimeInterval(86_400 - 1)
        f.hub.tokenLimits.checkExpired()
        XCTAssertNotNil(f.hub.tokenLimits.holds[f.ada.id])
        now = start.addingTimeInterval(86_400)
        f.hub.tokenLimits.checkExpired()
        XCTAssertNil(f.hub.tokenLimits.holds[f.ada.id])
        XCTAssertEqual(f.processes().count, 2)
        let resumed = try XCTUnwrap(f.processes().last)
        XCTAssertTrue(resumed.isAlive)
        await waitUntil { resumed.notifications > 0 }
        XCTAssertEqual(resumed.notifications, 1, "The message sent while it waited reaches it")
        XCTAssertEqual(f.hub.tokenLimits.used(by: f.ada)?.tokens, 100)
    }

    /// Changing a plan's limit holds or lets go its users at once, counting tokens already used.
    func testChangingAPlansLimitTakesEffectStraightAway() throws {
        let f = try fixture()
        f.runtime.start(agent: f.kai, repository: f.hub.repository)
        use(f, input: 500, at: 0)
        XCTAssertNil(f.hub.tokenLimits.used(by: f.ada), "No limit by default")
        XCTAssertNoThrow(try send(f, "Hello"))

        f.hub.access.setTokenLimit(HubTokenLimit(tokens: 400, length: 2, unit: .hours), in: f.plan)
        XCTAssertEqual(f.hub.tokenLimits.holds[f.ada.id], start.addingTimeInterval(2 * 3600))
        XCTAssertEqual(f.runtime.snapshot(for: f.kai.id).phase, .offline, "An idle bot stops at once")
        XCTAssertEqual(f.processes().first?.stops, 1)
        XCTAssertNoThrow(try send(f, "Again"))
        XCTAssertEqual(f.processes().count, 1)

        f.hub.access.setTokenLimit(HubTokenLimit(tokens: 600, length: 2, unit: .hours), in: f.plan)
        XCTAssertNil(f.hub.tokenLimits.holds[f.ada.id])
        XCTAssertEqual(f.processes().count, 2)

        // So does moving someone to a plan with a lower limit.
        let small = try f.hub.access.addPlan(named: "Small")
        f.hub.access.set(HubHarness(provider: .codex, profile: nil), included: true, in: small)
        f.hub.access.setTokenLimit(HubTokenLimit(tokens: 100, length: 1, unit: .weeks), in: small)
        f.hub.access.move(f.ada, to: small)
        XCTAssertEqual(f.hub.tokenLimits.holds[f.ada.id], start.addingTimeInterval(7 * 86_400))
    }

    /// Someone a bot is shared with talks with it on its owner's plan: their messages wait while its owner is out of tokens.
    func testSomeoneABotIsSharedWithCanStillWriteWhileItsOwnerIsOutOfTokens() throws {
        let f = try fixture()
        let grace = try f.hub.access.addUser(named: "Grace")
        let shared = try f.hub.bots.share(f.kai.id, with: [grace.id], for: f.ada)
        let theirs = try XCTUnwrap(f.hub.bots.bots(for: grace).first { $0.id == shared.id })
        f.hub.access.setTokenLimit(HubTokenLimit(tokens: 10, length: 3, unit: .days), in: f.plan)
        use(f, input: 10, at: 0)
        XCTAssertNotNil(f.hub.tokenLimits.holds[f.ada.id])
        _ = try f.hub.bots.send("Hi", id: UUID(), in: theirs.conversationID, for: grace)
        XCTAssertEqual(try f.hub.repository.loadMessages(conversationID: theirs.conversationID).filter { $0.author == .user }.count, 1)
        XCTAssertTrue(f.processes().isEmpty, "It does not start for them either")
        // Grace's own plan has no limit; what Ada's bot used is not hers.
        XCTAssertNil(f.hub.tokenLimits.holds[grace.id])
    }

    /// Devices show why a held bot does not answer and when it continues, in its status rather than in the
    /// conversation: its owner, and the people it is shared with. They hear to list the bots again.
    func testAHeldBotTellsDevicesWhyAndWhenItContinues() throws {
        let f = try fixture()
        let grace = try f.hub.access.addUser(named: "Grace")
        _ = try f.hub.bots.share(f.kai.id, with: [grace.id], for: f.ada)
        f.runtime.start(agent: f.kai, repository: f.hub.repository)
        f.hub.bots.checkForChanges()
        XCTAssertNil(try f.hub.bots.bots(for: f.ada).first?.pause)
        var events: [(UUID, LinkEvent)] = []
        f.hub.bots.onChange = { events.append(($0, $1)) }

        f.hub.access.setTokenLimit(HubTokenLimit(tokens: 400, length: 2, unit: .hours), in: f.plan)
        use(f, input: 500, at: 0)
        let pause = try XCTUnwrap(f.hub.bots.bots(for: f.ada).first?.pause)
        XCTAssertEqual(pause.summary, "Paused: plan limit")
        XCTAssertEqual(pause.until, start.addingTimeInterval(2 * 3600))
        XCTAssertFalse(pause.kickable, "Kick cannot lift a plan's limit")
        XCTAssertTrue(pause.detail?.contains("400 tokens your plan allows") == true, pause.detail ?? "")
        let theirs = try XCTUnwrap(f.hub.bots.bots(for: grace).first?.pause)
        XCTAssertEqual(theirs.summary, "Paused: plan limit")
        XCTAssertEqual(theirs.until, pause.until)
        f.hub.bots.checkForChanges()
        XCTAssertTrue(events.contains { $0.0 == f.ada.id && $0.1 == .botsChanged })
        XCTAssertTrue(events.contains { $0.0 == grace.id && $0.1 == .botsChanged })
        // Nothing is written in the conversation.
        XCTAssertTrue(try f.hub.repository.loadMessages(conversationID: f.conversation).isEmpty)

        events = []
        f.hub.access.setTokenLimit(nil, in: f.plan)
        XCTAssertNil(try f.hub.bots.bots(for: f.ada).first?.pause)
        f.hub.bots.checkForChanges()
        XCTAssertTrue(events.contains { $0.0 == f.ada.id && $0.1 == .botsChanged })
    }

    /// A bot that waits for Kick says why to its owner, who can Kick it; the people it is shared with see it waits.
    func testABotWaitingForKickSaysWhyToItsOwner() throws {
        let f = try fixture()
        let grace = try f.hub.access.addUser(named: "Grace")
        _ = try f.hub.bots.share(f.kai.id, with: [grace.id], for: f.ada)
        f.runtime.start(agent: f.kai, repository: f.hub.repository)
        let process = try XCTUnwrap(f.processes().last)
        process.set(.failed, failure: .recoveryFailed)
        let pause = try XCTUnwrap(f.hub.bots.bots(for: f.ada).first?.pause)
        XCTAssertEqual(pause.summary, "Paused: recovery interrupted")
        XCTAssertTrue(pause.kickable)
        XCTAssertEqual(pause.detail, f.runtime.snapshot(for: f.kai.id).detail)
        XCTAssertEqual(try f.hub.bots.bots(for: grace).first?.pause, LinkBotPause(summary: "Paused"))
        process.set(.ready)
        XCTAssertNil(try f.hub.bots.bots(for: f.ada).first?.pause)
    }
}
