import Foundation
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class StoreFixture {
    let runtime: RuntimeCoordinatorFixture
    let a: AgentRecord
    let b: AgentRecord
    let store: NoodleStore
    let directA: BotConversation
    let directB: BotConversation
    var repository: WorkspaceRepository { runtime.repository }
    init() throws {
        runtime = try RuntimeCoordinatorFixture()
        a = try runtime.agent("Ada")
        b = try runtime.agent("Grace")
        store = NoodleStore(repository: runtime.repository, runtime: runtime.runtime, connectsServices: false)
        let aID = a.id, bID = b.id
        directA = try XCTUnwrap(store.conversations.first { $0.participantIDs == [aID] })
        directB = try XCTUnwrap(store.conversations.first { $0.participantIDs == [bID] })
        XCTAssertTrue(store.storageReady, store.errorMessage ?? "Storage unavailable")
    }
    func group(_ participants: Set<UUID>? = nil, name: String = "Project", description: String = "Shared research") throws -> BotConversation {
        guard store.createGroup(named: name, publicDescription: description, participantIDs: participants ?? [a.id, b.id]) else {
            XCTFail(store.errorMessage ?? "Group creation failed")
            throw CancellationError()
        }
        return try XCTUnwrap(store.selectedConversation)
    }
    func cleanUp() { store.stopMonitoring(); runtime.cleanUp() }
}
