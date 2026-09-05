import XCTest
@testable import SuperBotCore

final class AgentHeartbeatTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let bob = UUID()
    private let builder = UUID()

    func testDefaultsAreEnabledAndThirtyMinutes() {
        let configuration = AgentHeartbeatConfiguration()
        XCTAssertTrue(configuration.isEnabled)
        XCTAssertTrue(configuration.isEnabled(for: bob))
        XCTAssertEqual(configuration.interval, 1_800)
    }

    func testNoHeartbeatBeforeDeadlineAndOneAtThirtyMinutes() {
        var scheduler = tracked()
        XCTAssertEqual(due(&scheduler, after: 1_799), [])
        XCTAssertEqual(due(&scheduler, after: 1_800), [bob])
        XCTAssertEqual(due(&scheduler, after: 1_800), [])
        XCTAssertEqual(due(&scheduler, after: 1_801), [])
        XCTAssertEqual(due(&scheduler, after: 3_600), [bob])
    }

    func testIncomingOrOutgoingActivityResetsTheWholeInterval() {
        var scheduler = tracked()
        scheduler.recordActivity(for: bob, at: start.addingTimeInterval(1_700))
        XCTAssertEqual(due(&scheduler, after: 1_800), [])
        scheduler.recordActivity(for: bob, at: start.addingTimeInterval(2_000))
        XCTAssertEqual(due(&scheduler, after: 3_799), [])
        XCTAssertEqual(due(&scheduler, after: 3_800), [bob])
    }

    func testPollingDoesNotResetInactivity() {
        var scheduler = tracked()
        for second in 1..<1_800 { XCTAssertEqual(due(&scheduler, after: Double(second)), []) }
        XCTAssertEqual(due(&scheduler, after: 1_800), [bob])
    }

    func testAgentsHaveIndependentTimers() {
        var scheduler = tracked()
        scheduler.recordActivity(for: builder, at: start.addingTimeInterval(900))
        let both: Set<UUID> = [bob, builder]
        XCTAssertEqual(scheduler.takeDueHeartbeats(readyAgentIDs: both, at: start.addingTimeInterval(1_800)), [bob])
        XCTAssertEqual(scheduler.takeDueHeartbeats(readyAgentIDs: both, at: start.addingTimeInterval(2_700)), [builder])
    }

    func testBusyStartingOfflineAndFailedAgentsAreNotEligible() {
        var scheduler = tracked()
        XCTAssertEqual(scheduler.takeDueHeartbeats(readyAgentIDs: [], at: start.addingTimeInterval(3_600)), [])
        // Completing work is itself activity; don't immediately wake the newly idle agent.
        scheduler.recordActivity(for: bob, at: start.addingTimeInterval(3_600))
        XCTAssertEqual(due(&scheduler, after: 3_601), [])
        XCTAssertEqual(due(&scheduler, after: 5_400), [bob])
    }

    func testLongSleepProducesOneHeartbeatNotCatchUpTurns() {
        var scheduler = tracked()
        XCTAssertEqual(due(&scheduler, after: 86_400), [bob])
        XCTAssertEqual(due(&scheduler, after: 86_401), [])
        XCTAssertEqual(due(&scheduler, after: 88_200), [bob])
    }

    func testDisabledByDefaultOverrideAndReenableStartsFresh() {
        var scheduler = tracked()
        scheduler.configure(.init(isEnabled: false), at: start.addingTimeInterval(500))
        XCTAssertEqual(due(&scheduler, after: 9_000), [])
        scheduler.configure(.init(), at: start.addingTimeInterval(9_000))
        XCTAssertEqual(due(&scheduler, after: 9_001), [])
        XCTAssertEqual(due(&scheduler, after: 10_800), [bob])
    }

    func testPerBotOptOutDoesNotDisableOtherBots() {
        var scheduler = tracked()
        scheduler.recordActivity(for: builder, at: start)
        scheduler.configure(.init(disabledAgentIDs: [bob]), at: start)
        XCTAssertEqual(scheduler.takeDueHeartbeats(readyAgentIDs: [bob, builder], at: start.addingTimeInterval(1_800)), [builder])
        scheduler.configure(.init(), at: start.addingTimeInterval(2_000))
        XCTAssertEqual(due(&scheduler, after: 2_001), [])
        XCTAssertEqual(due(&scheduler, after: 3_800), [bob])
    }

    func testChangingIntervalStartsFreshAndUnchangedSettingsDoNotReset() {
        var scheduler = tracked()
        scheduler.configure(.init(intervalMinutes: 5), at: start.addingTimeInterval(100))
        scheduler.configure(.init(intervalMinutes: 5), at: start.addingTimeInterval(200))
        XCTAssertEqual(due(&scheduler, after: 399), [])
        XCTAssertEqual(due(&scheduler, after: 400), [bob])
    }

    func testUnknownAndRemovedBotsDoNotGetHeartbeats() {
        var scheduler = tracked()
        scheduler.remove(bob)
        XCTAssertEqual(scheduler.takeDueHeartbeats(readyAgentIDs: [bob, builder], at: start.addingTimeInterval(1_800)), [])
    }

    func testIntervalIsBounded() {
        XCTAssertEqual(AgentHeartbeatConfiguration(intervalMinutes: -1).intervalMinutes, 1)
        XCTAssertEqual(AgentHeartbeatConfiguration(intervalMinutes: Int.max).intervalMinutes, 1_440)
    }

    func testPreferencesPersistAndMissingPreferencesDefaultToOn() {
        let suite = "SuperBot.HeartbeatTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AgentHeartbeatConfiguration.load(from: defaults), .init())
        let configured = AgentHeartbeatConfiguration(isEnabled: false, intervalMinutes: 45, disabledAgentIDs: [bob])
        configured.save(to: defaults)
        XCTAssertEqual(AgentHeartbeatConfiguration.load(from: defaults), configured)
    }

    func testHeartbeatIsNotMistakenForAnInboxChange() {
        XCTAssertEqual(AgentWakeReason.heartbeat.eventText, "<superbot-event type=\"heartbeat\" />")
        XCTAssertEqual(AgentWakeReason.inboxChanged.eventText, "<superbot-event type=\"inbox-changed\" />")
        XCTAssertTrue(AgentWakeReason.heartbeatInstructions.contains("finish silently"))
        XCTAssertTrue(AgentWakeReason.heartbeatInstructions.contains("does not authorize"))
    }

    private func tracked() -> AgentHeartbeatScheduler {
        var scheduler = AgentHeartbeatScheduler()
        scheduler.recordActivity(for: bob, at: start)
        return scheduler
    }

    private func due(_ scheduler: inout AgentHeartbeatScheduler, after seconds: TimeInterval) -> [UUID] {
        scheduler.takeDueHeartbeats(readyAgentIDs: [bob], at: start.addingTimeInterval(seconds))
    }
}
