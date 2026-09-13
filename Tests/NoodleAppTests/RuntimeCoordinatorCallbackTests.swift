import Foundation
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class RuntimeCoordinatorCallbackTests: XCTestCase {
    private func fixture() throws -> RuntimeCoordinatorFixture {
        let f = try RuntimeCoordinatorFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        return f
    }
    private func approval(_ agent: AgentRecord, id: Int = 1) throws -> AgentApprovalRequest {
        try XCTUnwrap(AgentApprovalRequest(agentID: agent.id, message: ["id": id,
            "method": "item/tool/requestUserInput", "params": ["questions": []]]))
    }

    func testReplacedRuntimeCannotOverwriteCurrentStatusApprovalsOrHeartbeat() throws {
        let f = try fixture(), agent = try f.agent(), old = try f.start(agent)
        let oldApproval = try approval(agent)
        old.launch.onApprovals([oldApproval])
        f.runtime.restart(agent: agent, repository: f.repository)
        let current = try XCTUnwrap(f.factory.processes.last), currentApproval = try approval(agent, id: 2)
        current.launch.onApprovals([currentApproval])
        old.transition(.failed, detail: "Late failure from stopped runtime")
        old.launch.onApprovals([oldApproval])
        old.launch.onHeartbeat()
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).phase, .ready)
        XCTAssertEqual(f.runtime.approvals.map(\.id), [currentApproval.id])
        XCTAssertNil(f.runtime.lastHeartbeatDates[agent.id])
        f.runtime.resolveApproval(oldApproval, allow: true)
        XCTAssertTrue(current.resolved.isEmpty)
        f.runtime.resolveApproval(currentApproval, allow: false, answers: ["question": "Answer"])
        XCTAssertEqual(current.resolved.count, 1)
        XCTAssertEqual(current.resolved.first?.0, currentApproval.id)
        XCTAssertEqual(current.resolved.first?.1, false)
        XCTAssertEqual(current.resolved.first?.2, ["question": "Answer"])
    }

    func testDeletedRuntimeCannotRecreateSnapshotOrApproval() throws {
        let f = try fixture(), agent = try f.agent(), process = try f.start(agent)
        f.runtime.stop(agentID: agent.id)
        process.transition(.working)
        process.launch.onApprovals([try approval(agent)])
        process.launch.onHeartbeat()
        XCTAssertNil(f.runtime.snapshots[agent.id])
        XCTAssertTrue(f.runtime.approvals.isEmpty)
        XCTAssertNil(f.runtime.lastHeartbeatDates[agent.id])
    }

    func testShutdownRejectsLateCallbacksBeforeTheNextLaunch() throws {
        let f = try fixture(), agent = try f.agent(), process = try f.start(agent)
        f.runtime.stopAll()
        process.transition(.working)
        process.launch.onApprovals([try approval(agent)])
        process.launch.onHeartbeat()
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).phase, .offline)
        XCTAssertTrue(f.runtime.approvals.isEmpty)
        XCTAssertNil(f.runtime.lastHeartbeatDates[agent.id])
    }

    func testRuntimeCannotPublishStateOrApprovalsForAnotherBot() throws {
        let f = try fixture(), a = try f.agent("A"), b = try f.agent("B")
        let first = try f.start(a), second = try f.start(b)
        let aApproval = try approval(a), bApproval = try approval(b)
        second.launch.onApprovals([bApproval])
        first.launch.onSnapshot(.init(agentID: b.id, phase: .failed, detail: "Wrong identity"))
        first.launch.onApprovals([aApproval, bApproval])
        XCTAssertEqual(f.runtime.snapshot(for: b.id).phase, .ready)
        XCTAssertEqual(Set(f.runtime.approvals.map(\.id)), [aApproval.id, bApproval.id])
        XCTAssertEqual(f.runtime.approvals.count, 2)
        first.launch.onApprovals([])
        XCTAssertEqual(f.runtime.approvals.map(\.id), [bApproval.id])
    }

    func testTerminatedRuntimeCannotOverwritePendingRecoveryStatus() async throws {
        let f = try fixture(), agent = try f.agent(), process = try f.start(agent)
        process.crash()
        _ = try await f.clock.next(.seconds(1))
        let recovery = f.runtime.snapshot(for: agent.id).detail
        process.transition(.ready)
        process.launch.onApprovals([try approval(agent)])
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).phase, .starting)
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).detail, recovery)
        XCTAssertTrue(f.runtime.approvals.isEmpty)
    }
}
