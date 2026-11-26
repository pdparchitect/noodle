import ComputerCore
import XCTest
@testable import ComputerEngine
@testable import NoodleComputer

@MainActor final class ComputerResourceTests: XCTestCase {
    private func stoppedComputer(_ kind: ComputerKind = .container) throws -> (ComputerStore, ComputerSession, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try ComputerStore(root: root)
        let computer = kind == .windows
            ? Computer(name: "Windows", kind: .windows, cpuCount: 2, memoryGiB: 4, diskGiB: 64)
            : Computer(name: "Shell", kind: kind, cpuCount: 2, memoryGiB: 2, diskGiB: 8)
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

    private func windowsDisk(_ store: ComputerStore, _ session: ComputerSession, gib: UInt64 = 64) throws -> URL {
        let disk = store.library.directory(for: session.id).appendingPathComponent("Disk.img")
        XCTAssertTrue(FileManager.default.createFile(atPath: disk.path, contents: nil))
        try FileHandle(forWritingTo: disk).truncate(atOffset: gib * 1_073_741_824)
        return disk
    }

    private func size(_ url: URL) throws -> UInt64 {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64)
    }

    func testAStoppedWindowsComputerGrowsItsDisk() throws {
        let (store, session, root) = try stoppedComputer(.windows)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try windowsDisk(store, session)
        try store.changeResources(session, cpus: 2, memoryGiB: 4, diskGiB: 80, networkEnabled: true)
        XCTAssertEqual(try size(disk), 80 * 1_073_741_824)
        XCTAssertEqual(try store.library.load().first?.diskGiB, 80)
        XCTAssertEqual(session.computer.diskGiB, 80)
    }

    func testAWindowsDiskNeverShrinks() throws {
        let (store, session, root) = try stoppedComputer(.windows)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try windowsDisk(store, session)
        try store.changeResources(session, cpus: 2, memoryGiB: 4, diskGiB: 72, networkEnabled: true)
        XCTAssertThrowsError(try store.changeResources(session, cpus: 2, memoryGiB: 4, diskGiB: 68, networkEnabled: true))
        XCTAssertEqual(try size(disk), 72 * 1_073_741_824)
        XCTAssertEqual(try store.library.load().first?.diskGiB, 72)
    }

    func testOnlyWindowsDisksChangeCapacity() throws {
        let (store, session, root) = try stoppedComputer()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try store.changeResources(session, cpus: 2, memoryGiB: 2, diskGiB: 16, networkEnabled: true))
        XCTAssertEqual(try store.library.load().first?.diskGiB, 8)
    }
}
