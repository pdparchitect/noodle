import NoodleCore
import XCTest

final class CalendarAccessTests: XCTestCase {
    private var root: URL!
    private let agent = UUID(), other = UUID()
    private let work = CalendarRecord(id: "B7D970DB", title: "Work", source: "iCloud", writable: true)
    private let holidays = CalendarRecord(id: "71694F17", title: "UK Holidays", source: "Subscribed", writable: false)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testMissingFileIsAnEmptyRegistry() throws {
        let assignments = try CalendarAssignments.load(root: root)
        XCTAssertTrue(assignments.calendars.isEmpty)
        XCTAssertTrue(assignments.assigned(to: agent).isEmpty)
    }

    func testAssignmentsSurviveASaveAndLoad() throws {
        var assignments = CalendarAssignments()
        assignments.calendars = [work, holidays]
        assignments.agents[agent.uuidString] = [work.id]
        try assignments.save(root: root)
        let loaded = try CalendarAssignments.load(root: root)
        XCTAssertEqual(loaded.calendars, [work, holidays])
        XCTAssertEqual(loaded.assigned(to: agent), [work.id])
        XCTAssertTrue(loaded.assigned(to: other).isEmpty)
        XCTAssertTrue(loaded.permits(work.id, agent: agent))
        XCTAssertFalse(loaded.permits(holidays.id, agent: agent))
        XCTAssertFalse(loaded.permits(nil, agent: agent))
    }

    func testAnUnsupportedVersionIsRefusedRatherThanIgnored() throws {
        try Data(#"{"version":2,"calendars":[],"agents":{}}"#.utf8)
            .write(to: root.appendingPathComponent("calendars.json"))
        XCTAssertThrowsError(try CalendarAssignments.load(root: root))
    }

    func testToolAssignmentsGrantNothingWhenTheRegistryIsUnreadable() throws {
        var assignments = CalendarAssignments()
        assignments.agents[agent.uuidString] = [work.id]
        XCTAssertEqual(assignments.toolAssignments(readable: true), [agent: [work.id]])
        XCTAssertTrue(assignments.toolAssignments(readable: false).isEmpty)
    }

    func testEmptySelectionsAreNotPublishedAsAssignments() throws {
        var assignments = CalendarAssignments()
        assignments.agents[agent.uuidString] = []
        let store = ToolAssignmentStore()
        store.replace("calendar", with: assignments.toolAssignments(readable: true))
        XCTAssertTrue(store.assignments(for: agent).ids("calendar").isEmpty)
    }
}
