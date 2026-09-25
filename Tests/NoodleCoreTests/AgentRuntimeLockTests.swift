import Darwin
import XCTest
@testable import NoodleCore

/// Only one harness may run for a bot, whatever happened to the host that started an earlier one.
final class AgentRuntimeLockTests: XCTestCase {
    private var root: URL!
    private var layout: AgentStorageLayout!
    private var descriptors: [Int32] = []
    private var holders: [Process] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        layout = AgentStorageLayout(package: root.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true))
        try layout.create()
    }

    override func tearDownWithError() throws {
        descriptors.forEach { close($0) }
        holders.filter(\.isRunning).forEach { kill($0.processIdentifier, SIGKILL); $0.waitUntilExit() }
        try FileManager.default.removeItem(at: root)
    }

    private func acquire() throws -> Int32 {
        let descriptor = try AgentRuntimeLock.acquire(layout: layout, grace: 10)
        descriptors.append(descriptor)
        return descriptor
    }

    private func refusal() -> String? {
        do { _ = try acquire(); return nil } catch { return error.localizedDescription }
    }

    /// A harness left running by a host that crashed or was killed: it holds the
    /// lock through its own descriptor, runs in the bot's workspace and leads its group.
    private func orphanedRuntime(directory: URL) throws -> Process {
        let lock = layout.runtime.appendingPathComponent("harness.lock")
        let descriptor = open(lock.path, O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/bin/sleep")
        holder.arguments = ["600"]
        holder.currentDirectoryURL = directory
        holder.standardInput = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try holder.run()
        holders.append(holder)
        XCTAssertEqual(getpgid(holder.processIdentifier), holder.processIdentifier)
        let record = Data("\(holder.processIdentifier)\n".utf8)
        XCTAssertEqual(record.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, record.count, 0) }, record.count)
        close(descriptor)
        return holder
    }

    func testSecondRuntimeIsRefusedWhileTheFirstHoldsTheBot() throws {
        _ = try acquire()
        XCTAssertEqual(refusal(), "This bot is already running in another process.")
    }

    func testRuntimeCanStartAgainOnceThePreviousOneExits() throws {
        close(try acquire())
        descriptors.removeAll()
        XCTAssertNil(refusal())
    }

    func testLockOutlivesTheHandOffToTheHarness() throws {
        let descriptor = try acquire()
        XCTAssertEqual(fcntl(descriptor, F_GETFD) & FD_CLOEXEC, 0)
        XCTAssertEqual(fcntl(descriptor, F_GETFL) & O_ACCMODE, O_RDONLY)
        let recorded = try String(contentsOf: layout.runtime.appendingPathComponent("harness.lock"), encoding: .utf8)
        XCTAssertEqual(recorded, "\(getpgrp())\n")
    }

    func testOrphanedRuntimeIsStoppedBeforeTheNewOneStarts() throws {
        let orphan = try orphanedRuntime(directory: layout.workspace)
        XCTAssertNil(refusal())
        kill(orphan.processIdentifier, SIGKILL)
        orphan.waitUntilExit()
        XCTAssertEqual(orphan.terminationStatus, SIGTERM)
    }

    func testHolderOutsideTheBotWorkspaceIsNeverKilled() throws {
        let stranger = try orphanedRuntime(directory: root)
        XCTAssertEqual(refusal(), "This bot is already running in another process.")
        XCTAssertTrue(stranger.isRunning)
    }
}
