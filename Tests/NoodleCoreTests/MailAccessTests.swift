import Foundation
import MailBridge
import XCTest
@testable import NoodleCore

final class MailAccessTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    /// Assignments and the mailbox list survive a save and a load, in a file only this user can read.
    func testAssignmentsRoundTripPrivately() throws {
        let agent = UUID(), mailbox = UUID()
        var value = MailAssignments()
        value.mailboxes = [RemoteMailbox(id: mailbox, name: "Bořek", address: "borek@mail.example.org")]
        value.agents[agent.uuidString] = [mailbox]
        try value.save(root: root)
        let loaded = try MailAssignments.load(root: root)
        XCTAssertEqual(loaded.mailboxes, value.mailboxes)
        XCTAssertEqual(loaded.assigned(to: agent), [mailbox])
        XCTAssertEqual(loaded.assigned(to: UUID()), [])
        let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("mail.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    /// No file means no assignments.
    func testAMissingFileAssignsNothing() throws {
        XCTAssertTrue(try MailAssignments.load(root: root).agents.isEmpty)
    }

    /// A file from a newer Noodle is refused, so it is never overwritten with less.
    func testANewerFileIsRefused() throws {
        try Data(#"{"version":2,"mailboxes":[],"agents":{}}"#.utf8).write(to: root.appendingPathComponent("mail.json"))
        XCTAssertThrowsError(try MailAssignments.load(root: root))
    }

    /// The broker gets each bot's mailbox ids as strings, and nothing at all when the file couldn't be read.
    func testTheBrokerGetsStringIDsAndFailsClosed() {
        let agent = UUID(), mailbox = UUID()
        var value = MailAssignments()
        value.agents[agent.uuidString] = [mailbox]
        value.agents["not-a-uuid"] = [UUID()]
        XCTAssertEqual(value.toolAssignments(readable: true), [agent: [mailbox.uuidString]])
        XCTAssertEqual(value.toolAssignments(readable: false), [:])
    }
}
