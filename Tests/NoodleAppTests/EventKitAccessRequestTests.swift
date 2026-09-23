import XCTest
import NoodleCore
@testable import Noodle

/// Granting reminders access. EventKit hands back a grant and then keeps answering
/// `notDetermined` when asked for the status, which left the tool row stuck on
/// "Allow access to choose reminder lists" however often the person pressed it.
@MainActor final class EventKitAccessRequestTests: XCTestCase {
    private func repository() throws -> WorkspaceRepository {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noodle-eventkit-access-\(UUID())").resolvingSymlinksInPath()
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return repository
    }

    private static let personal = EventKitList(id: "personal", title: "Personal", source: "iCloud", writable: true)

    private func controller(kind: EventKitAssignments.Kind = .reminderList,
                            status: @escaping @MainActor () -> EventKitController.Access,
                            request: @escaping @Sendable () async throws -> Bool,
                            lists: [EventKitList] = [personal]) throws -> EventKitController {
        try EventKitController(repository: repository(), kind: kind, status: status, request: request) { lists }
    }

    func testAGrantedRequestOutranksAStaleNotDeterminedStatus() async throws {
        let controller = try controller(status: { .notDetermined }, request: { true })
        await controller.requestAccess()
        XCTAssertEqual(controller.access, .granted)
        XCTAssertEqual(controller.registry.lists.map(\.title), ["Personal"])
        XCTAssertNil(controller.failure)
    }

    func testARefreshDoesNotUndoAGrantTheStatusStillHides() async throws {
        let controller = try controller(status: { .notDetermined }, request: { true })
        await controller.requestAccess()
        await controller.refresh()
        XCTAssertEqual(controller.access, .granted)
    }

    func testAWithdrawnGrantIsStillNoticed() async throws {
        nonisolated(unsafe) var answer = EventKitController.Access.notDetermined
        let controller = try controller(status: { answer }, request: { true })
        await controller.requestAccess()
        XCTAssertEqual(controller.access, .granted)
        answer = .denied
        await controller.refresh()
        XCTAssertEqual(controller.access, .denied)
    }

    func testARefusedRequestFallsBackToWhatMacOSReports() async throws {
        let controller = try controller(status: { .denied }, request: { false })
        await controller.requestAccess()
        XCTAssertEqual(controller.access, .denied)
    }

    func testAFailedRequestIsReportedAndLeavesAccessUngranted() async throws {
        struct Refused: LocalizedError { var errorDescription: String? { "Reminders are unavailable." } }
        let controller = try controller(status: { .notDetermined }, request: { throw Refused() })
        await controller.requestAccess()
        XCTAssertEqual(controller.access, .notDetermined)
        XCTAssertEqual(controller.failure, "Reminders are unavailable.")
    }
}
