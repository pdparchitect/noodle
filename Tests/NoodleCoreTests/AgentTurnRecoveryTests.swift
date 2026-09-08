import XCTest
@testable import NoodleCore

final class AgentTurnRecoveryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    private func recovery(_ name: String = "codex-runtime") -> AgentTurnRecovery {
        AgentTurnRecovery(sessionStateURL: root.appendingPathComponent(".agents/\(name).json"))
    }

    func testIdleAndCompletedTurnsDoNotWakeAfterRelaunch() throws {
        for name in ["codex-runtime", "codex-runtime-extended", "claude-runtime-extended"] {
            var turn = recovery(name)
            XCTAssertFalse(turn.hasUnfinishedTurn)
            try turn.finish()
            try turn.begin()
            XCTAssertTrue(recovery(name).hasUnfinishedTurn)
            try turn.finish()
            XCTAssertFalse(recovery(name).hasUnfinishedTurn)
            try turn.finish()
            XCTAssertFalse(recovery(name).hasUnfinishedTurn)
        }
    }

    func testKilledAppLeavesDurableIntentEvenWithNoUnreadMessages() throws {
        for name in ["codex-runtime", "codex-runtime-extended", "claude-runtime-extended"] {
            // Dispatch persisted intent, then discard all process-local state.
            do {
                var original = recovery(name)
                try original.begin()
            }
            var restarted = recovery(name)
            XCTAssertTrue(restarted.hasUnfinishedTurn)
            // Opening a session is not completion and must not clear the marker.
            try restarted.finish()
            XCTAssertTrue(recovery(name).hasUnfinishedTurn)
            try restarted.begin()
            XCTAssertTrue(recovery(name).hasUnfinishedTurn)
            try restarted.finish()
            XCTAssertFalse(recovery(name).hasUnfinishedTurn)
        }
    }

    func testAnotherCrashDuringRecoveryKeepsWakePending() throws {
        var original = recovery()
        try original.begin()
        var retry = recovery()
        try retry.begin()
        XCTAssertTrue(recovery().hasUnfinishedTurn)
        // A delayed result from the old process cannot mark the retry complete.
        try original.finish()
        XCTAssertTrue(recovery().hasUnfinishedTurn)
        try retry.finish()
        XCTAssertFalse(recovery().hasUnfinishedTurn)
    }

    func testMarkersAreIsolatedByProviderAccessModeAndBot() throws {
        var turn = recovery("codex-runtime-extended")
        try turn.begin()
        XCTAssertFalse(recovery("codex-runtime").hasUnfinishedTurn)
        XCTAssertFalse(recovery("claude-runtime-extended").hasUnfinishedTurn)
        let other = AgentTurnRecovery(sessionStateURL: root.appendingPathComponent("other/.agents/codex-runtime-extended.json"))
        XCTAssertFalse(other.hasUnfinishedTurn)
    }

    func testMarkerFailureIsReportedBeforeWorkCanBeDispatched() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: root.appendingPathComponent(".agents"))
        var turn = recovery()
        XCTAssertThrowsError(try turn.begin())
        XCTAssertFalse(turn.hasUnfinishedTurn)
    }

    func testMarkerDoesNotOverwriteSessionOrWorkspace() throws {
        let session = root.appendingPathComponent(".agents/claude-runtime-extended.json")
        try FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data("saved session".utf8)
        try data.write(to: session)
        var turn = AgentTurnRecovery(sessionStateURL: session)
        try turn.begin()
        try turn.finish()
        XCTAssertEqual(try Data(contentsOf: session), data)
    }
}
