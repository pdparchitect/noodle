import XCTest
@testable import Noodle
import NoodleCore

/// The Spaces menu and the sidebar's space picker offer the same spaces, in the same order.
@MainActor
final class SpaceChoiceTests: XCTestCase {
    func testChoicesListAllThenTheSpacesMadeAndShowTheOneChosen() throws {
        let f = try StoreFixture()
        defer { f.cleanUp() }
        UserDefaults.standard.removeObject(forKey: NoodleStore.spaceKey)
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: NoodleStore.spaceKey) }
        let store = NoodleStore(repository: f.repository, runtime: f.runtime.runtime, connectsServices: false)
        XCTAssertEqual(store.spaceChoices.map(\.choice), [.all], "Nothing to choose before a space is made.")

        let work = try XCTUnwrap(store.addSpace(named: "Work"))
        let home = try XCTUnwrap(store.addSpace(named: "Home"))
        XCTAssertEqual(store.spaceChoices.map(\.choice), [.all, .custom(work.id), .custom(home.id)])
        XCTAssertEqual(store.spaceChoices.map(\.title), ["All", "Work", "Home"])
        XCTAssertEqual(store.shownSpace, .custom(home.id), "A new space is shown.")

        store.show(.custom(work.id))
        XCTAssertEqual(store.shownSpace, .custom(work.id))
        XCTAssertEqual(store.shownCustomSpace?.id, work.id)
        store.show(.all)
        XCTAssertEqual(store.shownSpace, .all)
        XCTAssertTrue(store.isShowingAll)
    }
}
