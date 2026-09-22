import NoodleCore
import XCTest

final class EventKitAccessTests: XCTestCase {
    private var root: URL!
    private let agent = UUID(), other = UUID()
    private let work = EventKitList(id: "B7D970DB", title: "Work", source: "iCloud", writable: true)
    private let holidays = EventKitList(id: "71694F17", title: "UK Holidays", source: "Subscribed", writable: false)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testMissingFileIsAnEmptyRegistry() throws {
        for kind in EventKitAssignments.Kind.allCases {
            let assignments = try EventKitAssignments.load(root: root, kind: kind)
            XCTAssertTrue(assignments.lists.isEmpty, kind.rawValue)
            XCTAssertTrue(assignments.assigned(to: agent).isEmpty, kind.rawValue)
        }
    }

    func testAssignmentsSurviveASaveAndLoad() throws {
        for kind in EventKitAssignments.Kind.allCases {
            var assignments = EventKitAssignments()
            assignments.lists = [work, holidays]
            assignments.agents[agent.uuidString] = [work.id]
            try assignments.save(root: root, kind: kind)
            let loaded = try EventKitAssignments.load(root: root, kind: kind)
            XCTAssertEqual(loaded.lists, [work, holidays], kind.rawValue)
            XCTAssertEqual(loaded.assigned(to: agent), [work.id], kind.rawValue)
            XCTAssertTrue(loaded.assigned(to: other).isEmpty, kind.rawValue)
            XCTAssertTrue(loaded.permits(work.id, agent: agent), kind.rawValue)
            XCTAssertFalse(loaded.permits(holidays.id, agent: agent), kind.rawValue)
            XCTAssertFalse(loaded.permits(nil, agent: agent), kind.rawValue)
        }
    }

    func testCalendarsAndReminderListsAreKeptApart() throws {
        var calendars = EventKitAssignments()
        calendars.lists = [work]
        calendars.agents[agent.uuidString] = [work.id]
        try calendars.save(root: root, kind: .calendar)
        // Assigning a calendar must not assign a reminder list of the same bot.
        XCTAssertTrue(try EventKitAssignments.load(root: root, kind: .reminderList).assigned(to: agent).isEmpty)
        XCTAssertNotEqual(EventKitAssignments.Kind.calendar.file, EventKitAssignments.Kind.reminderList.file)
        XCTAssertEqual(EventKitAssignments.Kind.reminderList.rawValue, "reminder-list")
    }

    func testAnUnsupportedVersionIsRefusedRatherThanIgnored() throws {
        for kind in EventKitAssignments.Kind.allCases {
            try Data(#"{"version":2,"lists":[],"agents":{}}"#.utf8)
                .write(to: root.appendingPathComponent(kind.file))
            XCTAssertThrowsError(try EventKitAssignments.load(root: root, kind: kind), kind.rawValue)
        }
    }

    func testToolAssignmentsGrantNothingWhenTheRegistryIsUnreadable() throws {
        var assignments = EventKitAssignments()
        assignments.agents[agent.uuidString] = [work.id]
        XCTAssertEqual(assignments.toolAssignments(readable: true), [agent: [work.id]])
        XCTAssertTrue(assignments.toolAssignments(readable: false).isEmpty)
    }

    func testEmptySelectionsAreNotPublishedAsAssignments() throws {
        var assignments = EventKitAssignments()
        assignments.agents[agent.uuidString] = []
        let store = ToolAssignmentStore()
        store.replace(EventKitAssignments.Kind.reminderList.rawValue, with: assignments.toolAssignments(readable: true))
        XCTAssertTrue(store.assignments(for: agent).ids("reminder-list").isEmpty)
    }
}
