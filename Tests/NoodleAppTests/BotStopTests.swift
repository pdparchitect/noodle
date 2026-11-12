import Foundation
import NoodleCore
import XCTest
@testable import Noodle
@testable import NoodleRuntime

/// Stop ends a working bot's turn at once: the harness cancels it, then restarts with the same session so
/// nothing the turn started keeps running. The bot goes back to idle and leaves its unread messages for later.
@MainActor final class BotStopTests: XCTestCase {
    private func fixture() throws -> RuntimeCoordinatorFixture {
        let f = try RuntimeCoordinatorFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        return f
    }

    private func processes(_ f: RuntimeCoordinatorFixture, of agent: AgentRecord) -> [RuntimeProcessFixture] {
        f.factory.processes.filter { $0.configuration.id == agent.id }
    }

    /// Saved by the harness while it works: the session it resumes, and the mark of a turn it has not finished.
    private func sessionFiles(_ f: RuntimeCoordinatorFixture, of agent: AgentRecord) throws -> (session: URL, unfinished: URL) {
        let session = f.repository.storage(for: agent.id).sessionState(provider: .codex, extendedAccess: false)
        try FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"threadID":"kept"}"#.utf8).write(to: session)
        let unfinished = session.appendingPathExtension("unfinished")
        try Data("turn".utf8).write(to: unfinished)
        return (session, unfinished)
    }

    func testStopCancelsTheTurnThenRestartsTheHarnessKeepingTheSessionAndUnreadMessages() async throws {
        let f = try fixture(), agent = try f.agent("Ada")
        let turn = try f.start(agent)
        turn.hasInterruptedWork = true
        turn.transition(.working)
        let files = try sessionFiles(f, of: agent)
        let direct = try XCTUnwrap(f.repository.loadConversations().first { $0.participantIDs == [agent.id] })
        _ = try f.repository.sendUserMessage(conversationID: direct.id, body: "One more thing")

        XCTAssertTrue(f.runtime.canStopTurn(agent.id))
        XCTAssertTrue(f.runtime.stopTurn(agent: agent, repository: f.repository))
        XCTAssertEqual(turn.cancels, 1)
        XCTAssertEqual(turn.stops, 0, "The harness gets to end its turn first")
        XCTAssertFalse(f.runtime.canStopTurn(agent.id), "Stop is not offered twice")
        XCTAssertFalse(f.runtime.stopTurn(agent: agent, repository: f.repository))
        XCTAssertEqual(turn.cancels, 1)

        // The turn ends; the harness restarts so nothing it started keeps running.
        turn.transition(.ready)
        try await f.clock.waitUntil { self.processes(f, of: agent).count == 2 }
        XCTAssertEqual(turn.stops, 1)
        let next = try XCTUnwrap(processes(f, of: agent).last)
        XCTAssertFalse(next.launch.recoverInterruptedWork, "A stopped turn is not resumed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.session.path), "The session is kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.unfinished.path))
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).phase, .ready)

        // Its unread message waits for the next time it is woken.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(next.notifications.isEmpty, "It does not pick up its unread messages by itself")
        XCTAssertFalse(try f.repository.latestMessages(for: agent.id, consuming: false).isEmpty)
        XCTAssertFalse(f.runtime.canStopTurn(agent.id))
        f.runtime.notify([agent], repository: f.repository)
        XCTAssertEqual(next.notifications.count, 1)
    }

    func testAHarnessStillBusyAfterFiveSecondsIsRestarted() async throws {
        let f = try fixture(), agent = try f.agent("Ada")
        let turn = try f.start(agent)
        turn.transition(.working)
        XCTAssertTrue(f.runtime.stopTurn(agent: agent, repository: f.repository))
        try await f.clock.next(.seconds(5)).resolve(.success(()))
        try await f.clock.waitUntil { self.processes(f, of: agent).count == 2 }
        XCTAssertEqual(turn.stops, 1)
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).phase, .ready)
    }

    func testAHarnessThatCannotCancelATurnIsRestartedAtOnce() throws {
        let f = try fixture(), agent = try f.agent("Ada")
        let turn = try f.start(agent)
        turn.cancelsTurns = false
        turn.transition(.working)
        XCTAssertTrue(f.runtime.stopTurn(agent: agent, repository: f.repository))
        XCTAssertEqual(turn.stops, 1)
        XCTAssertEqual(processes(f, of: agent).count, 2)
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).phase, .ready)
    }

    /// Someone writing to the bot just after Stop gets an answer, rather than waiting for the next heartbeat.
    func testAMessageSentWhileItStopsIsPickedUp() async throws {
        let f = try fixture(), agent = try f.agent("Ada")
        let turn = try f.start(agent)
        turn.transition(.working)
        XCTAssertTrue(f.runtime.stopTurn(agent: agent, repository: f.repository))
        let direct = try XCTUnwrap(f.repository.loadConversations().first { $0.participantIDs == [agent.id] })
        _ = try f.repository.sendUserMessage(conversationID: direct.id, body: "Do this instead")
        f.runtime.notify([agent], repository: f.repository)
        turn.transition(.ready)
        try await f.clock.waitUntil { self.processes(f, of: agent).count == 2 }
        let next = try XCTUnwrap(processes(f, of: agent).last)
        try await f.clock.waitUntil { !next.notifications.isEmpty }
    }

    func testOnlyAWorkingBotCanBeStopped() throws {
        let f = try fixture(), agent = try f.agent("Ada")
        let process = try f.start(agent)
        XCTAssertFalse(f.runtime.canStopTurn(agent.id))
        XCTAssertFalse(f.runtime.stopTurn(agent: agent, repository: f.repository))
        XCTAssertEqual(process.cancels, 0)
        XCTAssertEqual(process.stops, 0)
        XCTAssertFalse(f.runtime.canStopTurn(UUID()))
    }

    // MARK: - Noodle

    private func store() throws -> StoreFixture {
        let f = try StoreFixture()
        addTeardownBlock { await MainActor.run { f.cleanUp() } }
        return f
    }

    func testStopIsOfferedOnlyWhileTheBotWorksAndSaysSoInItsConversation() async throws {
        let f = try store()
        f.store.startAgents()
        let turn = try XCTUnwrap(f.runtime.factory.processes.last { $0.configuration.id == f.a.id })
        XCTAssertFalse(f.store.canStop(f.a.id))
        turn.transition(.working)
        XCTAssertTrue(f.store.canStop(f.a.id))
        XCTAssertFalse(f.store.canStop(f.b.id))

        f.store.stop(agentID: f.a.id)
        XCTAssertEqual(turn.cancels, 1)
        XCTAssertFalse(f.store.canStop(f.a.id))
        let note = try XCTUnwrap(f.store.messagesByConversation[f.directA.id]?.last)
        XCTAssertEqual(note.author, .system)
        XCTAssertEqual(note.body, "You stopped Ada.")
        let saved = try f.repository.loadMessages(conversationID: f.directA.id).last
        XCTAssertEqual(saved?.id, note.id)
        // The bot reads it, unread, at the start of its next turn.
        XCTAssertTrue(try f.repository.latestMessages(for: f.a.id, consuming: false).contains { $0.message.id == note.id })
    }

    func testStopsDefaultShortcutIsCommandPeriod() {
        let binding = KeyboardShortcutPreferences().binding(for: .stopBot)
        XCTAssertEqual(binding?.displayName, "⌘.")
        XCTAssertEqual(binding?.isValid, true)
        XCTAssertNil(binding?.reservedAction)
    }
}
