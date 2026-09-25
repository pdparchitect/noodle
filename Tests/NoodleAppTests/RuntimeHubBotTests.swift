import Foundation
import NoodleCore
import XCTest
@testable import Noodle
@testable import NoodleRuntime

/// A bot that lives on a Noodle Hub runs there; this Mac only shows its conversation.
@MainActor final class RuntimeHubBotTests: XCTestCase {
    func testBotsOnAHubNeverStartHere() throws {
        let f = try RuntimeCoordinatorFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        let agent = try f.agent()
        f.runtime.remoteAgentIDs = [agent.id]
        f.runtime.startAll(agents: [agent], repository: f.repository)
        f.runtime.notify([agent], repository: f.repository)
        f.runtime.reconcile(agents: [agent], repository: f.repository, immediately: true)
        XCTAssertTrue(f.factory.processes.isEmpty)
        // Nothing here is restarting it either.
        XCTAssertNotEqual(f.runtime.snapshot(for: agent.id).phase, .starting)
        XCTAssertFalse(f.runtime.snapshot(for: agent.id).detail.contains("Restarting"))
    }

    func testABotMovedToAHubStopsHere() throws {
        let f = try RuntimeCoordinatorFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        let agent = try f.agent()
        let process = try f.start(agent)
        f.runtime.start(agent: agent, repository: f.repository)
        XCTAssertEqual(process.starts, 1)
        f.runtime.remoteAgentIDs = [agent.id]
        XCTAssertEqual(process.stops, 1)
    }
}
