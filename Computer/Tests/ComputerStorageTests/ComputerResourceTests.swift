import ComputerCore
import XCTest
@testable import ComputerEngine
@testable import NoodleComputer

@MainActor final class ComputerResourceTests: XCTestCase {
    private func stoppedComputer() throws -> (ComputerStore, ComputerSession, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try ComputerStore(root: root)
        let computer = Computer(name: "Shell", kind: .container, cpuCount: 2, memoryGiB: 2, diskGiB: 8)
        try FileManager.default.createDirectory(at: store.library.stagingDirectory(for: computer.id), withIntermediateDirectories: true)
        let session = ComputerSession(try store.library.commit(computer))
        store.sessions = [session]
        return (store, session, root)
    }

    func testAStoppedComputerKeepsNewResources() throws {
        let (store, session, root) = try stoppedComputer()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.changeResources(session, cpus: 1, memoryGiB: 4, networkEnabled: false)
        let saved = try XCTUnwrap(store.library.load().first)
        XCTAssertEqual([saved.cpuCount, saved.memoryGiB], [1, 4])
        XCTAssertFalse(saved.networkEnabled)
        XCTAssertEqual(session.computer, saved)
    }

    func testARunningComputerKeepsItsResources() throws {
        let (store, session, root) = try stoppedComputer()
        defer { try? FileManager.default.removeItem(at: root) }
        session.phase = .running
        XCTAssertThrowsError(try store.changeResources(session, cpus: 1, memoryGiB: 4, networkEnabled: true))
        XCTAssertEqual(try store.library.load().first?.memoryGiB, 2)
    }

    func testResourcesOutsideTheLimitsAreRefused() throws {
        let (store, session, root) = try stoppedComputer()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try store.changeResources(session, cpus: 1, memoryGiB: 999, networkEnabled: true))
        XCTAssertThrowsError(try store.changeResources(session, cpus: 0, memoryGiB: 2, networkEnabled: true))
        XCTAssertEqual(session.computer.memoryGiB, 2)
    }
}
