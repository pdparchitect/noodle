import XCTest
@testable import NoodleCore

final class ClaudeSessionStateTests: XCTestCase {
    private func missing(_ id: UUID) -> [String: Any] {
        ["type": "result", "subtype": "error_during_execution", "is_error": true,
         "num_turns": 0, "session_id": id.uuidString.lowercased(),
         "errors": ["No conversation found with session ID: \(id.uuidString.lowercased())"]]
    }

    func testStartupDoesNotPersistUnconfirmedSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.json")
        var state = ClaudeSessionState(url: url)
        XCTAssertFalse(state.shouldResume)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertThrowsError(try state.confirm(sessionID: UUID()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try state.confirm(sessionID: state.sessionID)
        XCTAssertTrue(state.shouldResume)
        XCTAssertEqual(ClaudeSessionState(url: url).sessionID, state.sessionID)
    }

    func testStructuredMissingSessionErrorBreaksResumeLoop() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.json")
        var original = ClaudeSessionState(url: url)
        try original.confirm(sessionID: original.sessionID)
        let memory = root.appendingPathComponent("memory.md")
        try "Keep my work".write(to: memory, atomically: true, encoding: .utf8)
        var resumed = ClaudeSessionState(url: url)
        XCTAssertTrue(resumed.shouldResume)
        XCTAssertTrue(try resumed.invalidateMissingSession(from: missing(resumed.sessionID)))
        let restarted = ClaudeSessionState(url: url)
        XCTAssertFalse(restarted.shouldResume)
        XCTAssertNotEqual(restarted.sessionID, original.sessionID)
        XCTAssertEqual(try String(contentsOf: memory, encoding: .utf8), "Keep my work")
    }

    func testUnrelatedErrorsAndInitializedSessionPreservePointer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.json")
        var state = ClaudeSessionState(url: url)
        try state.confirm(sessionID: state.sessionID)
        XCTAssertFalse(try state.invalidateMissingSession(from: missing(state.sessionID)))
        var resumed = ClaudeSessionState(url: url)
        var error = missing(state.sessionID)
        for description in ["Authentication failed", "Rate limit exceeded", "Model unavailable", "Transport disconnected"] {
            error["errors"] = [description]
            XCTAssertFalse(try resumed.invalidateMissingSession(from: error))
        }
        XCTAssertFalse(try resumed.invalidateMissingSession(from: missing(UUID())))
        error = missing(state.sessionID)
        error["num_turns"] = 1
        XCTAssertFalse(try resumed.invalidateMissingSession(from: error))
        XCTAssertEqual(ClaudeSessionState(url: url).sessionID, state.sessionID)
    }

    func testOlderRuntimeCannotRemoveNewerSessionPointer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.json")
        var original = ClaudeSessionState(url: url)
        try original.confirm(sessionID: original.sessionID)
        var old = ClaudeSessionState(url: url)
        var newer = ClaudeSessionState(url: root.appendingPathComponent("new.json"))
        try newer.confirm(sessionID: newer.sessionID)
        try Data(contentsOf: root.appendingPathComponent("new.json")).write(to: url)
        XCTAssertTrue(try old.invalidateMissingSession(from: missing(old.sessionID)))
        XCTAssertEqual(ClaudeSessionState(url: url).sessionID, newer.sessionID)
    }
}
