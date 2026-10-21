import Foundation
import MailBridge
import NoodleCore
import XCTest
@testable import Noodle

/// Bots reach mailboxes through the Mail tool extension and Noodle's tool broker
/// (MailToolProviderTests). This controller owns the assignments the broker enforces.
@MainActor final class MailBrokerTests: XCTestCase {
    private struct Fixture {
        let repository: WorkspaceRepository
        let agent: AgentRecord
        let controller: MailController
        let mailbox: UUID
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("library")); try repository.prepare()
        let agent = try repository.createAgent(named: "Mail test").agent
        let mailbox = UUID()
        let controller = MailController(repository: repository, connection: { _ in
            var response = MailResponse()
            response.mailboxes = [RemoteMailbox(id: mailbox, name: "Bořek", address: "borek@mail.example.org")]
            return response
        })
        await controller.refresh()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return .init(repository: repository, agent: agent, controller: controller, mailbox: mailbox)
    }

    /// Assignments reach the broker at once and on every change, and an unreadable file revokes them all.
    func testAssignmentsArePublishedAndAnUnreadableFileGrantsNothing() async throws {
        let f = try await fixture()
        var published: [[UUID: Set<String>]] = []
        f.controller.onAssignmentsChange = { published.append($0) }
        XCTAssertEqual(published, [[:]], "the current picture is published as soon as someone listens")
        try f.controller.assign([f.mailbox], to: f.agent)
        XCTAssertEqual(published.last, [f.agent.id: [f.mailbox.uuidString]])
        try f.controller.assign([], to: f.agent)
        XCTAssertEqual(published.last?[f.agent.id] ?? [], [])

        try f.controller.assign([f.mailbox], to: f.agent)
        try Data("not json".utf8).write(to: f.repository.rootURL.appendingPathComponent("mail.json"))
        XCTAssertThrowsError(try f.controller.reloadAssignments())
        XCTAssertEqual(published.last, [:], "a file that cannot be read must revoke, not keep, access")
    }

    /// The mailbox list from Noodle Mail is kept, and only listed mailboxes can be assigned.
    func testOnlyListedMailboxesCanBeAssigned() async throws {
        let f = try await fixture()
        XCTAssertTrue(f.controller.available)
        XCTAssertEqual(f.controller.registry.mailboxes.map(\.name), ["Bořek"])
        XCTAssertThrowsError(try f.controller.assign([UUID()], to: f.agent, synchronizeWorkspace: false))
        XCTAssertNoThrow(try f.controller.assign([f.mailbox], to: f.agent, synchronizeWorkspace: false))
        XCTAssertEqual(f.controller.selectedIDs(for: f.agent), [f.mailbox])
    }

    /// A failed bot save puts mail.json back as it was.
    func testACheckpointRestoresMailAssignments() async throws {
        let f = try await fixture()
        try f.controller.assign([f.mailbox], to: f.agent, synchronizeWorkspace: false)
        let checkpoint = try AgentSettingsCheckpoint(repository: f.repository)
        try f.controller.assign([], to: f.agent, synchronizeWorkspace: false)
        try checkpoint.restore()
        try f.controller.reloadAssignments()
        XCTAssertEqual(f.controller.selectedIDs(for: f.agent), [f.mailbox])
    }
}
