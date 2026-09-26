import Foundation
import NoodleCore
import XCTest

/// A scheduled deletion survives failures and restarts until it succeeds once.
@MainActor final class DeletionJournalTests: XCTestCase {
    private struct Refused: Error {}
    private final class Counter { var value = 0 }

    private func journalURL() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-deletions-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("Nested/pending-deletions.json")
    }

    func testAFailedDeletionIsRetriedAfterARestartUntilItSucceeds() async throws {
        let url = journalURL(), kept = UUID(), gone = UUID()
        let journal = DeletionJournal<UUID>(url: url)
        try journal.schedule([kept, gone])
        let failure = await journal.run { id in if id == kept { throw Refused() } }
        XCTAssertTrue(failure is Refused)
        XCTAssertEqual(journal.scheduled, [kept])

        let restarted = DeletionJournal<UUID>(url: url)
        XCTAssertEqual(restarted.scheduled, [kept], "The failed deletion was not kept on disk")
        var deleted: [UUID] = []
        let none = await restarted.run { deleted.append($0) }
        XCTAssertNil(none)
        XCTAssertEqual(deleted, [kept])
        XCTAssertEqual(DeletionJournal<UUID>(url: url).scheduled, [])
    }

    func testADeletionUnderWayIsNotStartedTwice() async throws {
        let journal = DeletionJournal<UUID>(url: journalURL()), id = UUID()
        try journal.schedule([id])
        let calls = Counter()
        let gate = AsyncStream<Void>.makeStream()
        let first = Task { await journal.run { _ in calls.value += 1; for await _ in gate.stream { break } } }
        while calls.value == 0 { await Task.yield() }
        _ = await journal.run { _ in calls.value += 1 }
        gate.continuation.yield()
        _ = await first.value
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(journal.scheduled, [])
    }
}
