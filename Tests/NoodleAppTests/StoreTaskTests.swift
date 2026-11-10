import XCTest
@testable import Noodle
import NoodleCore

@MainActor
final class StoreTaskTests: XCTestCase {
    func testTasksFollowTheShownSpace() throws {
        let f = try StoreFixture()
        defer { f.cleanUp() }
        UserDefaults.standard.removeObject(forKey: NoodleStore.spaceKey)
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: NoodleStore.spaceKey) }
        _ = try f.repository.addTask(agentID: f.a.id, title: "A's task", conversationID: f.directA.id)
        _ = try f.repository.addTask(agentID: f.b.id, title: "B's task")
        let store = NoodleStore(repository: f.repository, runtime: f.runtime.runtime, connectsServices: false)
        XCTAssertEqual(Set(store.openTasks(waitingOnMeOnly: false).map(\.task.title)), ["A's task", "B's task"])

        let space = try XCTUnwrap(store.addSpace(named: "Work"))
        store.setMember(true, of: space.id, conversationID: f.directA.id)
        XCTAssertEqual(store.openTasks(waitingOnMeOnly: false).map(\.task.title), ["A's task"])

        // A task without a conversation goes with its bot's own.
        store.setMember(true, of: space.id, conversationID: f.directB.id)
        XCTAssertEqual(Set(store.openTasks(waitingOnMeOnly: false).map(\.task.title)), ["A's task", "B's task"])

        store.showSpace(nil)
        XCTAssertEqual(store.openTasks(waitingOnMeOnly: false).count, 2)
    }
}
