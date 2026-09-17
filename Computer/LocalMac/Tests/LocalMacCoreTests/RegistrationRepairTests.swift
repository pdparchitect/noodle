import Foundation
import XCTest
@testable import LocalMacCore

@MainActor final class RegistrationRepairTests: XCTestCase {
    func testReplacementRegistersOnlyAfterUnregisterCompletes() async throws {
        let repair = LocalMacRegistrationRepair()
        var events: [String] = []
        let result = try await repair.repair(status: { .enabled }, verify: { events.append("verify") }, unregister: {
            events.append("unregister")
            await Task.yield()
            XCTAssertEqual(events, ["verify", "unregister"])
            events.append("reaped")
        }, register: { events.append("register") })
        XCTAssertEqual(events, ["verify", "unregister", "reaped", "register"])
        XCTAssertEqual(result, .enabled)
        XCTAssertFalse(repair.inProgress)
    }
    func testApprovalNeverUnregistersOrRegisters() async throws {
        let result = try await LocalMacRegistrationRepair().repair(status: { .requiresApproval },
            verify: { XCTFail("Approval does not require repair") },
            unregister: { XCTFail("Must preserve user's approval choice") },
            register: { XCTFail("Must open native approval instead") })
        XCTAssertEqual(result, .requiresApproval)
    }
    func testInvalidReplacementLeavesRegisteredServiceUntouched() async {
        do {
            _ = try await LocalMacRegistrationRepair().repair(status: { .enabled },
                verify: { throw LocalMacError("invalid signature") },
                unregister: { XCTFail("Must verify before stopping the helper") },
                register: { XCTFail("Must not install invalid code") })
            XCTFail("Must fail verification")
        } catch { XCTAssertEqual(error.localizedDescription, "invalid signature") }
    }
    func testUnregisterFailureDoesNotRaceRegistration() async {
        let repair = LocalMacRegistrationRepair()
        do {
            _ = try await repair.repair(status: { .enabled }, verify: {},
                unregister: { throw LocalMacError("still running") },
                register: { XCTFail("Must wait for a successful shutdown") })
            XCTFail("Must report shutdown failure")
        } catch { XCTAssertFalse(repair.inProgress) }
    }
    func testInterruptedRegistrationCanBeRetriedWithoutUnregisteringAgain() async throws {
        let repair = LocalMacRegistrationRepair()
        var status: LocalMacRegistrationStatus = .enabled
        var stops = 0, starts = 0
        for attempt in 0..<2 {
            do {
                _ = try await repair.repair(status: { status }, verify: {}, unregister: {
                    stops += 1; status = .notRegistered
                }, register: {
                    starts += 1
                    if attempt == 0 { throw LocalMacError("registration interrupted") }
                    status = .requiresApproval
                })
                XCTAssertEqual(attempt, 1)
            } catch { XCTAssertEqual(attempt, 0) }
        }
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(status, .requiresApproval)
    }
    func testRepeatedRepairCannotRunConcurrently() async throws {
        let repair = LocalMacRegistrationRepair()
        _ = try await repair.repair(status: { .enabled }, verify: {}, unregister: {
            do {
                _ = try await repair.repair(status: { .enabled }, verify: { XCTFail("Second repair must be rejected") },
                    unregister: { XCTFail("Second shutdown") }, register: { XCTFail("Second registration") })
                XCTFail("Must reject concurrent repair")
            } catch { XCTAssertTrue(repair.inProgress) }
        }, register: {})
        XCTAssertFalse(repair.inProgress)
    }
    func testTransientDisabledDispositionRetriesRegistrationWithoutAnotherShutdown() async throws {
        var status: LocalMacRegistrationStatus = .enabled
        var stops = 0, starts = 0, pauses = 0
        let result = try await LocalMacRegistrationRepair().repair(status: { status }, verify: {}, unregister: {
            stops += 1; status = .notRegistered
        }, register: {
            starts += 1
            if starts < 3 { throw NSError(domain: "SMAppServiceErrorDomain", code: 1) }
            status = .enabled
        }, pause: { pauses += 1 })
        XCTAssertEqual(result, .enabled)
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(starts, 3)
        XCTAssertEqual(pauses, 2)
    }
    func testApprovalDuringRepairEndsRetries() async throws {
        var status: LocalMacRegistrationStatus = .enabled
        var starts = 0
        let result = try await LocalMacRegistrationRepair().repair(status: { status }, verify: {}, unregister: {
            status = .notRegistered
        }, register: {
            starts += 1; status = .requiresApproval
            throw NSError(domain: "SMAppServiceErrorDomain", code: 1)
        }, pause: { XCTFail("Approval is not transient") })
        XCTAssertEqual(result, .requiresApproval)
        XCTAssertEqual(starts, 1)
    }
    func testRegistrationRaceHasABoundedRetryAndDoesNotRetryOtherFailures() async {
        for code in [1, 3, 4, 10] {
            var status: LocalMacRegistrationStatus = .enabled
            var starts = 0, pauses = 0
            do {
                _ = try await LocalMacRegistrationRepair().repair(status: { status }, verify: {}, unregister: {
                    status = .notRegistered
                }, register: {
                    starts += 1; throw NSError(domain: "SMAppServiceErrorDomain", code: code)
                }, pause: { pauses += 1 })
                XCTFail("Must report persistent failure")
            } catch {
                XCTAssertEqual(starts, code == 1 ? 6 : 1)
                XCTAssertEqual(pauses, code == 1 ? 5 : 0)
            }
        }
    }
}
