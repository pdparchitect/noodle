import XCTest
@testable import NoodleCore

final class TranscriptPositionStoreTests: XCTestCase {
    func testReadingPositionsSurviveRelaunchAndStayPerConversation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("scroll-positions.json")
        let dm = UUID(), group = UUID(), message = UUID()
        let store = TranscriptPositionStore(fileURL: file)
        let reading = TranscriptViewport(offset: 1234, isAtBottom: false, messageID: message)
        try store.save(reading, for: dm)
        try store.save(TranscriptViewport(offset: 8000, isAtBottom: true), for: group)

        let relaunched = TranscriptPositionStore(fileURL: file)
        XCTAssertEqual(relaunched.viewport(for: dm), reading)
        XCTAssertTrue(relaunched.viewport(for: group).isAtBottom)
        XCTAssertEqual(relaunched.viewport(for: UUID()), TranscriptViewport())
        XCTAssertEqual(relaunched.viewport(for: dm).restored(availableMessageIDs: [message]), reading)
        XCTAssertEqual(relaunched.viewport(for: dm).restored(availableMessageIDs: []), TranscriptViewport())
        try relaunched.retainConversations([group])
        XCTAssertEqual(TranscriptPositionStore(fileURL: file).viewport(for: dm), TranscriptViewport())
        XCTAssertTrue(TranscriptPositionStore(fileURL: file).viewport(for: group).isAtBottom)
    }

    func testCorruptAndInvalidPositionsFailSafely() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("scroll-positions.json"), id = UUID()
        try Data("not JSON".utf8).write(to: file)
        let store = TranscriptPositionStore(fileURL: file)
        XCTAssertEqual(store.viewport(for: id), TranscriptViewport())
        for offset: CGFloat in [-1, .infinity, .nan] {
            let invalid = TranscriptViewport(offset: offset, isAtBottom: false)
            try store.save(invalid, for: id)
            XCTAssertEqual(store.viewport(for: id), TranscriptViewport())
            XCTAssertEqual(invalid.restored(availableMessageIDs: []), TranscriptViewport())
        }
        let message = UUID()
        try store.save(.init(offset: 400, isAtBottom: false, messageID: message), for: id)
        XCTAssertEqual(TranscriptPositionStore(fileURL: file).viewport(for: id).messageID, message)
    }

    func testWorkspaceIsolationAndNoMessageContents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("production/scroll-positions.json")
        let production = TranscriptPositionStore(fileURL: file)
        let development = TranscriptPositionStore(fileURL: root.appendingPathComponent("development/scroll-positions.json"))
        let id = UUID(), message = UUID()
        try production.save(.init(offset: 200, isAtBottom: false, messageID: message), for: id)
        XCTAssertEqual(development.viewport(for: id), TranscriptViewport())
        let encoded = try JSONEncoder().encode(production.viewport(for: id))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["offset", "isAtBottom", "messageID"])
    }
}
