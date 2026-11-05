import ComputerCore
import Foundation
import LocalMacCore
import XCTest
@testable import ComputerEngine
@testable import NoodleComputer

@MainActor final class LocalMacDeletionTests: XCTestCase {
    func testLocalMacCanBeDeletedWhileRunningFailedOrAwaitingSetup() {
        let session = ComputerSession(Computer(name: "Fixture", kind: .localMac))
        session.localMac = LocalMacComputer()
        for phase: ComputerPhase in [.stopped, .running, .failed("Timed out"), .setupRequired(.requiresApproval)] {
            session.phase = phase
            XCTAssertTrue(session.canDelete, "Deletion must remain available in \(phase)")
        }
        for phase: ComputerPhase in [.starting, .stopping, .updating] {
            session.phase = phase; XCTAssertFalse(session.canDelete)
        }
        let container = ComputerSession(Computer(name: "Container", kind: .container))
        container.phase = .running; XCTAssertFalse(container.canDelete)
        container.phase = .failed("Unknown state"); XCTAssertTrue(container.canDelete)
        container.phase = .stopped; XCTAssertTrue(container.canDelete)
    }

    func testAFailedStartWithNothingLeftRunningCanBeDeleted() {
        let session = ComputerSession(Computer(name: "Failed", kind: .container))
        session.recordStartupFailure(ComputerError("The container did not start."))
        XCTAssertEqual(session.phase, .failed("The container did not start."))
        XCTAssertTrue(session.canDelete)
    }

    func testAFailedComputerThatStillHoldsARuntimeCannotBeDeleted() {
        let session = ComputerSession(Computer(name: "Windows", kind: .windows))
        session.windowsRuntime = NSObject()
        session.phase = .failed("Could not stop Windows")
        XCTAssertFalse(session.canDelete)
        session.windowsRuntime = nil
        XCTAssertTrue(session.canDelete)
    }

    func testAStartThatRanOutOfDiskSpaceSaysSo() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let wrapped = NSError(domain: "Containerization", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "unpack failed", NSUnderlyingErrorKey: posix])
        let outOfSpace = "This Mac is out of free space. Free some in Settings → Storage, then start again."
        for error in [wrapped, NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)] {
            let session = ComputerSession(Computer(name: "Full", kind: .container))
            session.recordStartupFailure(error)
            XCTAssertEqual(session.phase, .failed(outOfSpace))
            XCTAssertTrue(session.canDelete)
        }
        let other = ComputerSession(Computer(name: "Other", kind: .container))
        other.recordStartupFailure(ComputerError("Timed out"))
        XCTAssertEqual(other.phase, .failed("Timed out"))
    }

    func testFailedDesktopDeletionReachesLifecycleOnceAndRetainsRecordOnFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var calls: [UUID] = []
        let attempted = expectation(description: "Lifecycle deletion attempted")
        let store = try ComputerStore(root: root, removeLocalMacAccount: { id in
            calls.append(id); attempted.fulfill()
            throw ComputerError("Cannot stop the background session")
        })
        var computer = Computer(name: "Failed", kind: .localMac)
        computer.localMacSetupRequested = true
        try FileManager.default.createDirectory(at: store.library.stagingDirectory(for: computer.id), withIntermediateDirectories: true)
        let session = ComputerSession(try store.library.commit(computer))
        session.localMac = LocalMacComputer(); session.phase = .failed("Desktop request timed out")
        store.sessions = [session]; store.selection = session.id
        store.remove(session)
        XCTAssertEqual(session.phase, .stopping)
        XCTAssertFalse(session.canDelete)
        store.remove(session) // A second click cannot submit another deletion.
        await fulfillment(of: [attempted], timeout: 2)
        XCTAssertEqual(calls, [session.id])
        XCTAssertEqual(store.sessions.map(\.id), [session.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.library.directory(for: session.id).path))
        XCTAssertEqual(session.phase, .failed("Desktop request timed out"))
        XCTAssertTrue(session.canDelete)
        XCTAssertEqual(store.error, "Cannot stop the background session")
    }
}
