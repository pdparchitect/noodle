import Foundation
import NoodleCore
import XCTest
@testable import Noodle
@testable import NoodleRuntime

@MainActor final class RuntimeCoordinatorUsageTests: XCTestCase {
    func testHarnessMessagesBecomeSamplesForTheirBotAndRuntime() throws {
        let f = try RuntimeCoordinatorFixture()
        defer { f.cleanUp() }
        var samples: [UsageSample] = []
        f.runtime.onUsage = { samples.append($0) }
        let agent = try f.agent("Ada", harness: .claudeCode)
        let first = try f.start(agent)
        func result(output: Int, cost: Double) -> [String: Any] {
            ["type": "result", "modelUsage": ["claude-opus-5-5": ["outputTokens": output, "costUSD": cost]]]
        }
        first.launch.onActivity(result(output: 10, cost: 0.1))
        first.launch.onActivity(result(output: 25, cost: 0.3))
        XCTAssertEqual(samples.map(\.tokens.output), [10, 15])
        XCTAssertEqual(samples.last?.agentID, agent.id)
        XCTAssertEqual(samples.last?.agentName, "Ada")
        XCTAssertEqual(samples.last?.harness, "claude-code")
        XCTAssertEqual(samples.last?.model, "claude-opus-5-5")
        XCTAssertEqual(samples.last?.date, f.clock.date)

        // A new runtime starts its own totals, and the old one's late messages are ignored.
        f.runtime.restart(agent: agent, repository: f.repository)
        let second = try XCTUnwrap(f.factory.processes.last)
        XCTAssertFalse(second === first)
        first.launch.onActivity(result(output: 40, cost: 0.5))
        second.launch.onActivity(result(output: 25, cost: 0.3))
        XCTAssertEqual(samples.map(\.tokens.output), [10, 15, 25])
    }
}
