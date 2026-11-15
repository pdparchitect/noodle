import NoodleCore
import XCTest

/// Agents' tasks, listed as Noodle lists them: those waiting on the champion first, then the ones in progress,
/// then those waiting on someone else; and a reply about one goes to its conversation, carrying the task.
@MainActor final class TaskTests: XCTestCase {
    func testOpenTasksAreOrderedAndAReplyCarriesTheTask() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PionTasks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PionModel(root: root, messenger: nil, isScripted: true)
        model.start()
        let avery = try model.createAgent(name: "Avery", description: nil, instructions: "", provider: .codex, model: nil)
        let direct = try XCTUnwrap(model.directConversation(of: avery))
        let busy = try model.repository.addTask(agentID: avery.id, title: "Pull sign-in logs", now: Date(timeIntervalSince1970: 100))
        let asks = try model.repository.addTask(agentID: avery.id, title: "Approve the block", now: Date(timeIntervalSince1970: 50))
        _ = try model.repository.updateTask(agentID: avery.id, id: asks.id, state: .waiting, waitingOn: .user, now: Date(timeIntervalSince1970: 60))
        let done = try model.repository.addTask(agentID: avery.id, title: "Old", now: Date(timeIntervalSince1970: 10))
        _ = try model.repository.updateTask(agentID: avery.id, id: done.id, state: .done)
        model.reloadTasks(of: avery.id)

        XCTAssertEqual(model.openTasks(waitingOnMeOnly: false).map(\.task.title), ["Approve the block", "Pull sign-in logs"])
        XCTAssertEqual(model.openTasks(waitingOnMeOnly: true).map(\.task.title), ["Approve the block"])

        try model.sendFeedback("Approved, go ahead.", on: asks, of: avery.id)
        let sent = try XCTUnwrap(model.messages(in: direct.id).last)
        XCTAssertEqual(sent.body, "Approved, go ahead.")
        XCTAssertEqual(sent.task?.id, asks.id)
        _ = busy
    }
}
