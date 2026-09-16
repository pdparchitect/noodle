import XCTest
@testable import NoodleCore

final class WorkspaceMailboxMonitorTests: XCTestCase {
    func testIdleMailboxesSkipScansAndAtomicRequestsWakeThem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mailbox = try WorkspaceMailbox(workspace: root, path: ".noodle/test", create: true)
        let monitor = WorkspaceMailboxMonitor(rescanInterval: 60)
        XCTAssertTrue(monitor.hasChanges(now: 0))
        XCTAssertTrue(monitor.needsScan(workspace: root, path: ".noodle/test", now: 0))
        for _ in 0..<1000 {
            XCTAssertFalse(monitor.hasChanges(now: 1))
            XCTAssertFalse(monitor.needsScan(workspace: root, path: ".noodle/test", now: 1))
        }
        try mailbox.writeData(Data("request".utf8), named: "new.request")
        var observed = false
        for _ in 0..<100 {
            if monitor.needsScan(workspace: root, path: ".noodle/test", now: 2) {
                observed = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(observed, "Atomic request publication must wake an idle mailbox before the fallback scan")
        XCTAssertTrue(monitor.hasChanges(now: 60), "Periodic recovery must also pass the idle fast path")
    }

    func testPeriodicReattachmentRecoversReplacedParentsAndMissingMailboxes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = WorkspaceMailboxMonitor()
        let path = ".noodle/test"
        XCTAssertTrue(monitor.needsScan(workspace: root, path: path, now: 0))
        XCTAssertFalse(monitor.needsScan(workspace: root, path: path, now: 1))
        _ = try WorkspaceMailbox(workspace: root, path: path, create: true)
        XCTAssertTrue(monitor.needsScan(workspace: root, path: path, now: 5))
        try FileManager.default.moveItem(at: root.appendingPathComponent(".noodle"),
                                        to: root.appendingPathComponent("old"))
        let replacement = try WorkspaceMailbox(workspace: root, path: path, create: true)
        XCTAssertTrue(monitor.needsScan(workspace: root, path: path, now: 10))
        try replacement.writeData(Data(), named: "new.request")
        var observed = false
        for _ in 0..<100 {
            if monitor.needsScan(workspace: root, path: path, now: 11) { observed = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(observed, "The replacement mailbox must have its own watcher")
        monitor.reset()
        XCTAssertTrue(monitor.needsScan(workspace: root, path: path, now: 11))
    }
}
