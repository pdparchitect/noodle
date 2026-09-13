import Foundation
import NoodleCore
import NoodleSharing
import XCTest

@MainActor final class ShareComposerTests: XCTestCase {
    private func fixture() throws -> ShareFixture {
        let f = try ShareFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        return f
    }

    func testTextIsTrimmedDeduplicatedAndPublishedToTheSelectedDestinationOnce() async throws {
        let f = try fixture()
        try await f.load([.text(" First \n"), .text("Second"), .text("First"), .text(" \n")])
        XCTAssertEqual(f.model.destinations, f.destinations)
        XCTAssertEqual(f.model.destinationID, f.destinations[0].id)
        XCTAssertEqual(f.model.text, "First\n\nSecond")
        f.model.destinationID = f.destinations[1].id
        f.model.instruction = "  Summarize this \n"
        XCTAssertTrue(f.model.canSend)
        try f.model.send()
        let request = try XCTUnwrap(f.inbox.pending().first)
        XCTAssertEqual(request.conversationID, f.destinations[1].id)
        XCTAssertEqual(request.body, "Summarize this\n\nFirst\n\nSecond")
        XCTAssertTrue(request.filenames.isEmpty)
        XCTAssertFalse(f.model.canSend)
        XCTAssertThrowsError(try f.model.send())
        XCTAssertEqual(try f.inbox.pending().count, 1)
    }

    func testEmptyContentAndMissingDestinationCannotBeSent() async throws {
        let f = try fixture()
        XCTAssertFalse(f.model.canSend)
        try await f.load([.text(" \n ")])
        XCTAssertFalse(f.model.canSend)
        XCTAssertThrowsError(try f.model.send())
        f.model.instruction = "Only an instruction"
        XCTAssertTrue(f.model.canSend)
        f.model.destinationID = nil
        XCTAssertFalse(f.model.canSend)
        XCTAssertThrowsError(try f.model.send())
        XCTAssertTrue(try f.inbox.pending().isEmpty)
    }

    func testDuplicateNamesAndManifestFilenameAreCopiedWithoutOverwriting() async throws {
        let f = try fixture()
        let first = try f.file("one/report.txt", bytes: Data([0, 255, 1]))
        let second = try f.file("two/report.txt", bytes: Data([2, 128, 3]))
        let manifest = try f.file("request.json", bytes: Data("user content".utf8))
        try await f.load([.file(first), .file(second), .file(manifest)])
        XCTAssertNil(f.model.error)
        XCTAssertEqual(f.model.filenames, ["report.txt", "report 2.txt", "Shared request.json"])
        try f.model.send()
        let request = try XCTUnwrap(f.inbox.pending().first)
        let bytes = try f.inbox.files(for: request).map { try Data(contentsOf: $0) }
        XCTAssertEqual(bytes, [Data([0, 255, 1]), Data([2, 128, 3]), Data("user content".utf8)])
        XCTAssertEqual(try Data(contentsOf: first), bytes[0])
        XCTAssertEqual(try Data(contentsOf: second), bytes[1])
    }

    func testImportFailureCannotPublishPartialContent() async throws {
        let f = try fixture()
        try await f.load([.text("Partial text"), .file(f.root.appendingPathComponent("missing.txt"))])
        XCTAssertNotNil(f.model.error)
        XCTAssertFalse(f.model.canSend)
        XCTAssertThrowsError(try f.model.send())
        XCTAssertTrue(try f.inbox.pending().isEmpty)
    }

    func testCancelledComposerCannotPublishAndRemovesOnlyItsDraft() async throws {
        for includeFile in [false, true] {
            let f = try fixture(), original = try f.file("original.txt")
            try await f.load([.text("Cancelled content")] + (includeFile ? [.file(original)] : []))
            XCTAssertEqual(try f.drafts().count, 1)
            f.model.cancel()
            XCTAssertFalse(f.model.canSend)
            XCTAssertThrowsError(try f.model.send())
            XCTAssertTrue(try f.drafts().isEmpty)
            XCTAssertTrue(try f.inbox.pending().isEmpty)
            XCTAssertEqual(try Data(contentsOf: original), Data("Shared bytes".utf8))
        }
    }

    func testPublishFailureLeavesDraftAvailableForRetry() async throws {
        let f = try fixture(), original = try f.file("original.txt")
        try await f.load([.file(original)])
        let draft = try XCTUnwrap(f.drafts().first)
        let collision = f.inbox.rootURL.appendingPathComponent("Pending/" + draft.lastPathComponent)
        try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: false)
        XCTAssertThrowsError(try f.model.send())
        XCTAssertFalse(f.model.isSending)
        XCTAssertTrue(f.model.canSend)
        XCTAssertEqual(f.model.filenames, ["original.txt"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: draft.appendingPathComponent("original.txt").path))
        try FileManager.default.removeItem(at: collision)
        try f.model.send()
        XCTAssertEqual(try f.inbox.pending().count, 1)
        XCTAssertTrue(try f.drafts().isEmpty)
    }

    func testCancelAfterPublicationKeepsTheQueuedRequestAndFiles() async throws {
        let f = try fixture(), original = try f.file("original.txt")
        try await f.load([.file(original)])
        try f.model.send()
        f.model.cancel()
        let request = try XCTUnwrap(f.inbox.pending().first)
        XCTAssertEqual(try f.inbox.files(for: request).map { try Data(contentsOf: $0) }, [Data("Shared bytes".utf8)])
        XCTAssertTrue(try f.drafts().isEmpty)
    }
}
