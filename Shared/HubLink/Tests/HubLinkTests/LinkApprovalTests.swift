import Foundation
import HubLink
import XCTest

/// What a device tells its person of a bot's held calls as each list of them comes: every new one once, and those
/// decided anywhere taken back.
final class LinkApprovalTests: XCTestCase {
    private func approval(_ id: UUID = UUID(), at seconds: TimeInterval = 0) -> LinkApproval {
        LinkApproval(id: id, conversationID: UUID(), providerTitle: "Google Workspace Containment", tool: "suspend",
                     input: #"{"user":"m.okafor@kestrel.example"}"#, reason: "Phished", createdAt: Date(timeIntervalSince1970: seconds))
    }

    func testOnlyNewOnesAreAnnouncedAndDecidedOnesAreTakenBack() {
        let kept = approval(at: 1), arrived = approval(at: 2), decided = UUID()
        let changes = LinkApproval.changes(listed: [arrived, kept], known: [kept.id, decided])
        XCTAssertEqual(changes.new.map(\.id), [arrived.id])
        XCTAssertEqual(changes.gone, [decided])
        XCTAssertEqual(changes.pending, [kept.id, arrived.id])
        let again = LinkApproval.changes(listed: [arrived, kept], known: changes.pending)
        XCTAssertTrue(again.new.isEmpty)
        XCTAssertTrue(again.gone.isEmpty)
    }

    func testNewOnesAreAnnouncedOldestFirstAndEachHasItsOwnNotification() {
        let older = approval(at: 1), newer = approval(at: 2)
        XCTAssertEqual(LinkApproval.changes(listed: [newer, older], known: []).new.map(\.id), [older.id, newer.id])
        XCTAssertEqual(older.notificationIdentifier, "approval-\(older.id.uuidString)")
        XCTAssertEqual(LinkApproval.notificationIdentifier(older.id), older.notificationIdentifier)
    }
}
