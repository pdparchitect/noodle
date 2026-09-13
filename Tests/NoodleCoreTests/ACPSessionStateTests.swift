import XCTest
@testable import NoodleCore

final class ACPSessionStateTests: XCTestCase {
    private func stateFile() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("grok-runtime.json")
    }

    func testRecoveryPreservesOldReferenceAndUnfinishedWorkAcrossReload() throws {
        let url = try stateFile(), old = UUID().uuidString
        let legacy = try JSONSerialization.data(withJSONObject: ["sessionID": old])
        try legacy.write(to: url)
        var work = AgentTurnRecovery(sessionStateURL: url)
        try work.begin()
        let marker = try Data(contentsOf: url.appendingPathExtension("unfinished"))
        try ACPSessionState.prepareRecovery(at: url, replacing: old)
        let state = try JSONDecoder().decode(ACPSessionState.self, from: Data(contentsOf: url))
        XCTAssertNil(state.sessionID)
        XCTAssertEqual(state.previousSessionIDs, [old])
        XCTAssertTrue(state.needsHistoryRecovery)
        XCTAssertFalse(state.recoveryBlocked)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("unfinished")), marker)
    }

    func testStaleConfirmationAndCorruptStateCannotOverwriteSession() throws {
        let url = try stateFile()
        for data in [try JSONEncoder().encode(ACPSessionState(sessionID: UUID().uuidString)), Data("broken state".utf8)] {
            try data.write(to: url)
            XCTAssertThrowsError(try ACPSessionState.prepareRecovery(at: url, replacing: UUID().uuidString))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testExplicitRetryRetainsReplacementAndHistoryRecoveryIntent() throws {
        let url = try stateFile()
        var state = ACPSessionState(sessionID: UUID().uuidString)
        state.previousSessionIDs = [UUID().uuidString]
        state.needsHistoryRecovery = true
        state.recoveryBlocked = true
        try state.save(to: url)
        try ACPSessionState.allowRecoveryRetry(at: url)
        let retried = try JSONDecoder().decode(ACPSessionState.self, from: Data(contentsOf: url))
        state.recoveryBlocked = false
        XCTAssertEqual(retried, state)
    }
}
