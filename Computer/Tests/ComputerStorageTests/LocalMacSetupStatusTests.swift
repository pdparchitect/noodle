import ComputerCore
import LocalMacCore
import XCTest
@testable import NoodleComputer

@MainActor final class LocalMacSetupStatusTests: XCTestCase {
    func testExpectedSetupIsNotAComputerFailure() {
        let session = ComputerSession(Computer(name: "First Mac", kind: .localMac))
        for status: LocalMacRegistrationStatus in [.notRegistered, .requiresApproval] {
            session.recordStartupFailure(LocalMacSetupRequired(registration: status))
            XCTAssertEqual(session.phase, .setupRequired(status))
            XCTAssertTrue(session.phase.canStart)
            XCTAssertFalse(session.phase.busy)
            XCTAssertFalse(session.localMacSetupRequired) // No repair action.
            XCTAssertTrue(session.console.isEmpty)
            XCTAssertFalse(session.phase.startFailureDescription.contains("did not start"))
        }
        XCTAssertEqual(session.phase.label, "Approval required")
    }
    func testEnabledButUnresponsiveAndUnknownStatusRemainRealFailures() {
        let session = ComputerSession(Computer(name: "Mac", kind: .localMac))
        for status: LocalMacRegistrationStatus in [.enabled, .helperMissing, .unknown] {
            let error = LocalMacSetupRequired(registration: status)
            session.recordStartupFailure(error)
            XCTAssertEqual(session.phase, .failed(error.localizedDescription))
            XCTAssertTrue(session.localMacSetupRequired)
            XCTAssertFalse(error.localizedDescription.hasPrefix("Allow "))
        }
    }
    func testApprovalRefreshDoesNotStartOrCreateAnAccount() async {
        let session = ComputerSession(Computer(name: "First Mac", kind: .localMac))
        await session.refreshLocalMacSetup(read: { .notRegistered })
        XCTAssertEqual(session.phase, .setupRequired(.notRegistered))
        await session.refreshLocalMacSetup(read: { .requiresApproval })
        XCTAssertEqual(session.phase, .setupRequired(.requiresApproval))
        await session.refreshLocalMacSetup(read: { .enabled })
        XCTAssertEqual(session.phase, .stopped)
        XCTAssertNil(session.localMac)
        XCTAssertNil(session.computer.localMacSetupRequested)
    }
    func testUnavailableRefreshPreservesLastKnownApprovalAndEnabledDoesNotHideAFailure() async {
        let session = ComputerSession(Computer(name: "Mac", kind: .localMac))
        session.phase = .setupRequired(.requiresApproval)
        await session.refreshLocalMacSetup(read: { .unknown })
        XCTAssertEqual(session.phase, .setupRequired(.requiresApproval))
        session.recordStartupFailure(LocalMacSetupRequired(registration: .enabled))
        let failure = session.phase
        await session.refreshLocalMacSetup(read: { .enabled })
        XCTAssertEqual(session.phase, failure)
        XCTAssertTrue(session.localMacSetupRequired)
        await session.refreshLocalMacSetup(read: { .helperMissing })
        XCTAssertEqual(session.phase, .failed(LocalMacSetupRequired(registration: .helperMissing).localizedDescription))
    }
    func testStatusRefreshCannotReplaceAnInFlightStart() async {
        let session = ComputerSession(Computer(name: "Mac", kind: .localMac))
        await session.refreshLocalMacSetup(read: {
            session.phase = .starting
            return .notRegistered
        })
        XCTAssertEqual(session.phase, .starting)
    }
}
