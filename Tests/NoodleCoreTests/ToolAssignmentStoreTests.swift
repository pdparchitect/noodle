import XCTest
@testable import NoodleCore

final class ToolAssignmentStoreTests: XCTestCase {
    func testEachKindIsReplacedWholesaleAndKindsStayIndependent() {
        let store = ToolAssignmentStore(), ada = UUID(), grace = UUID()
        XCTAssertEqual(store.assignments(for: ada), .none)
        store.replace("browser", with: [ada: ["b1", "b2"], grace: ["b3"]])
        store.replace("computer", with: [ada: ["c1"]])
        XCTAssertEqual(store.assignments(for: ada), ["browser": ["b1", "b2"], "computer": ["c1"]])
        store.replace("browser", with: [grace: ["b3"]])
        XCTAssertEqual(store.assignments(for: ada), ["computer": ["c1"]], "an agent missing from the new snapshot loses that kind")
        XCTAssertEqual(store.assignments(for: grace), ["browser": ["b3"]])
        store.replace("browser", with: [grace: []])
        XCTAssertEqual(store.assignments(for: grace), .none, "an empty set is no assignment")
    }

    func testBrowserAssignmentsPublishNothingWhenTheRegistryCouldNotBeRead() throws {
        let ada = UUID(), browser = UUID()
        var registry = BrowserAssignments()
        registry.agents[ada.uuidString] = [browser]
        registry.agents["not-a-uuid"] = [UUID()]
        XCTAssertEqual(registry.toolAssignments(readable: true), [ada: [browser.uuidString]])
        XCTAssertEqual(registry.toolAssignments(readable: false), [:], "an unreadable registry must fail closed")
    }
}
