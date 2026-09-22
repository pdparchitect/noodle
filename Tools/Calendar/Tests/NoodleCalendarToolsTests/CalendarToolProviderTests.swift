import NoodleCore
import XCTest
@testable import NoodleCalendarTools

final class CalendarToolProviderTests: XCTestCase {
    private let work = CalendarRecord(id: "11111111-1111-1111-1111-111111111111", title: "Work", source: "iCloud", writable: true)
    private let family = CalendarRecord(id: "22222222-2222-2222-2222-222222222222", title: "Family", source: "iCloud", writable: true)
    private let holidays = CalendarRecord(id: "33333333-3333-3333-3333-333333333333", title: "UK Holidays", source: "Subscribed", writable: false)
    private let agent = UUID()
    private var store: FakeCalendars!
    private var provider: CalendarToolProvider!
    private let registry = ToolProviderRegistry()

    /// Stands in for EventKit so these tests need no calendar access, no account and no UI.
    private final class FakeCalendars: CalendarStore, @unchecked Sendable {
        private let lock = NSLock()
        private var state: (calendars: [CalendarRecord], events: [CalendarEventRecord]) = ([], [])
        private(set) var queries: [(calendar: String, from: Date, to: Date, query: String?, limit: Int)] = []
        private(set) var created: [(calendar: String, draft: CalendarEventDraft)] = []
        private(set) var updated: [(id: String, draft: CalendarEventDraft, span: CalendarSpan)] = []
        private(set) var deleted: [(id: String, span: CalendarSpan)] = []

        init(calendars: [CalendarRecord], events: [CalendarEventRecord]) { state = (calendars, events) }
        func calendars() async throws -> [CalendarRecord] { lock.withLock { state.calendars } }
        func events(in calendar: String, from: Date, to: Date, query: String?, limit: Int) async throws -> [CalendarEventRecord] {
            lock.withLock {
                queries.append((calendar, from, to, query, limit))
                return state.events.filter { $0.calendarID == calendar && $0.start < to && $0.end > from }
            }
        }
        func event(_ id: String) async throws -> CalendarEventRecord? { lock.withLock { state.events.first { $0.id == id } } }
        func create(in calendar: String, draft: CalendarEventDraft) async throws -> CalendarEventRecord {
            lock.withLock {
                created.append((calendar, draft))
                let event = CalendarEventRecord(id: "new-event", calendarID: calendar, title: draft.title ?? "",
                                                start: draft.start ?? .distantPast, end: draft.end ?? .distantFuture,
                                                isAllDay: draft.isAllDay ?? false, location: draft.location, notes: draft.notes, url: draft.url)
                state.events.append(event)
                return event
            }
        }
        func update(_ id: String, draft: CalendarEventDraft, span: CalendarSpan) async throws -> CalendarEventRecord {
            try lock.withLock {
                updated.append((id, draft, span))
                guard let index = state.events.firstIndex(where: { $0.id == id }) else { throw ToolProviderError("No such event.") }
                if let title = draft.title { state.events[index].title = title }
                if let start = draft.start { state.events[index].start = start }
                if let end = draft.end { state.events[index].end = end }
                return state.events[index]
            }
        }
        func delete(_ id: String, span: CalendarSpan) async throws {
            lock.withLock { deleted.append((id, span)); state.events.removeAll { $0.id == id } }
        }
    }

    override func setUpWithError() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        store = FakeCalendars(calendars: [work, family, holidays], events: [
            CalendarEventRecord(id: "event-standup", calendarID: work.id, title: "Standup", start: start, end: start.addingTimeInterval(1800)),
            CalendarEventRecord(id: "event-secret", calendarID: family.id, title: "Surprise party", start: start, end: start.addingTimeInterval(3600))
        ])
        provider = CalendarToolProvider(store: store)
        try registry.register(provider)
    }

    private func call(_ tool: String, _ arguments: [String: Any], assigned: Set<String>? = nil) async throws -> [String: Any] {
        let request = ToolBridgeRequest(session: "s", action: .call, provider: "calendar", tool: tool,
                                        arguments: try JSONSerialization.data(withJSONObject: arguments))
        let granted = assigned ?? [work.id]
        let data = try await ToolBroker.perform(request, registry: registry, assignments: { ["calendar": granted] },
                                                context: ToolCallContext(agentID: agent, workspace: URL(fileURLWithPath: "/")))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func structured(_ result: [String: Any]) throws -> [String: Any] {
        XCTAssertNotEqual(result["isError"] as? Bool, true, String(describing: result["content"]))
        return try XCTUnwrap(result["structuredContent"] as? [String: Any])
    }
    private func message(_ result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    func testManifestAndToolListFollowTheProviderContract() async throws {
        XCTAssertNoThrow(try provider.manifest.validate())
        XCTAssertEqual(provider.manifest.id, "calendar")
        XCTAssertEqual(provider.kind, .builtIn)
        XCTAssertEqual(provider.manifest.activation, .whenAssigned("calendar"))
        let context = ToolCallContext(agentID: agent, workspace: URL(fileURLWithPath: "/"))
        let tools = try ToolDescriptor.list(mcp: try await provider.tools(context: context))
        XCTAssertEqual(tools.map(\.name), ["list", "events", "create", "update", "delete"])
        let list = try XCTUnwrap(tools.first { $0.name == "list" })
        XCTAssertEqual(list.resourceList, ToolResourceList(kind: "calendar", path: "calendars"))
        XCTAssertTrue(list.resourceParameters.isEmpty)
        for tool in tools where tool.name != "list" {
            XCTAssertEqual(tool.resourceParameters, [ToolResourceParameter(name: "calendar", kind: "calendar")], tool.name)
            XCTAssertTrue(tool.required.contains("calendar"), tool.name)
            XCTAssertFalse(tool.description.isEmpty, tool.name)
        }
        XCTAssertTrue(try XCTUnwrap(tools.first { $0.name == "events" }).retryable)
        for name in ["create", "update", "delete"] {
            XCTAssertFalse(try XCTUnwrap(tools.first { $0.name == name }).retryable, "\(name) changes a calendar, so a timed-out call must not repeat")
        }
    }

    func testListShowsOnlyTheCalendarsAssignedToThisBot() async throws {
        let listed = try structured(await call("list", [:]))
        let calendars = try XCTUnwrap(listed["calendars"] as? [[String: Any]])
        XCTAssertEqual(calendars.map { $0["id"] as? String }, [work.id])
        XCTAssertEqual(calendars.first?["title"] as? String, "Work")
        XCTAssertEqual(calendars.first?["writable"] as? Bool, true)
    }

    func testAnUnassignedCalendarIsRefusedBeforeTheStoreIsTouched() async throws {
        // The broker refuses before the provider runs, so this is a thrown refusal, not a result.
        do { _ = try await call("events", ["calendar": family.id]); XCTFail("Expected a refusal.") } catch {}
        XCTAssertTrue(store.queries.isEmpty)
    }

    func testEventsReadsOnlyTheNamedCalendarWithinTheRequestedRange() async throws {
        let structured = try structured(await call("events", [
            "calendar": work.id, "start": "2027-01-15T00:00:00Z", "end": "2027-01-16T00:00:00Z", "query": "stand", "limit": 5]))
        let events = try XCTUnwrap(structured["events"] as? [[String: Any]])
        XCTAssertEqual(events.map { $0["title"] as? String }, ["Standup"])
        XCTAssertEqual(events.first?["id"] as? String, "event-standup")
        let query = try XCTUnwrap(store.queries.first)
        XCTAssertEqual(store.queries.count, 1)
        XCTAssertEqual(query.calendar, work.id)
        XCTAssertEqual(query.query, "stand")
        XCTAssertEqual(query.limit, 5)
        XCTAssertEqual(query.from, ISO8601DateFormatter().date(from: "2027-01-15T00:00:00Z"))
        XCTAssertEqual(query.to, ISO8601DateFormatter().date(from: "2027-01-16T00:00:00Z"))
    }

    func testEventsRefusesAnUnreadableDate() async throws {
        let result = try await call("events", ["calendar": work.id, "start": "next tuesday"])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertTrue(store.queries.isEmpty)
    }

    func testCreateAuthorizesBeforeWritingAndReturnsTheEvent() async throws {
        let structured = try structured(await call("create", [
            "calendar": work.id, "title": "Design review", "start": "2027-02-01T10:00:00Z", "end": "2027-02-01T11:00:00Z",
            "location": "Studio", "notes": "Bring the spike"]))
        let event = try XCTUnwrap(structured["event"] as? [String: Any])
        XCTAssertEqual(event["id"] as? String, "new-event")
        XCTAssertEqual(event["calendar"] as? String, work.id)
        let created = try XCTUnwrap(store.created.first)
        XCTAssertEqual(store.created.count, 1)
        XCTAssertEqual(created.calendar, work.id)
        XCTAssertEqual(created.draft.title, "Design review")
        XCTAssertEqual(created.draft.location, "Studio")
        XCTAssertEqual(created.draft.notes, "Bring the spike")
        XCTAssertEqual(created.draft.end, ISO8601DateFormatter().date(from: "2027-02-01T11:00:00Z"))
    }

    func testCreateRefusesACalendarThatCannotBeChanged() async throws {
        let result = try await call("create", ["calendar": holidays.id, "title": "Day off", "start": "2027-02-01T10:00:00Z"],
                                    assigned: [holidays.id])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertTrue(message(result).lowercased().contains("read-only") || message(result).lowercased().contains("cannot be changed"), message(result))
        XCTAssertTrue(store.created.isEmpty)
    }

    func testCreateNeedsATitleAndAStart() async throws {
        for arguments in [["calendar": work.id, "start": "2027-02-01T10:00:00Z"], ["calendar": work.id, "title": "No when"]] {
            do { _ = try await call("create", arguments); XCTFail("Expected a refusal for \(arguments).") } catch {}
        }
        XCTAssertTrue(store.created.isEmpty)
    }

    func testUpdateRefusesAnEventThatLivesInAnotherCalendar() async throws {
        let result = try await call("update", ["calendar": work.id, "event": "event-secret", "title": "Renamed"])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertTrue(store.updated.isEmpty, "an event in an unassigned calendar must never be written")
        XCTAssertTrue(message(result).lowercased().contains("calendar"), message(result))
    }

    func testUpdateChangesOnlyTheFieldsGiven() async throws {
        let structured = try structured(await call("update", ["calendar": work.id, "event": "event-standup", "title": "Standup (moved)"]))
        XCTAssertEqual((structured["event"] as? [String: Any])?["title"] as? String, "Standup (moved)")
        let update = try XCTUnwrap(store.updated.first)
        XCTAssertEqual(update.id, "event-standup")
        XCTAssertEqual(update.draft.title, "Standup (moved)")
        XCTAssertNil(update.draft.start)
        XCTAssertNil(update.draft.end)
        XCTAssertEqual(update.span, .event)
    }

    func testDeleteRemovesTheEventAndHonoursTheSpan() async throws {
        _ = try structured(await call("delete", ["calendar": work.id, "event": "event-standup", "span": "future"]))
        XCTAssertEqual(store.deleted.map(\.id), ["event-standup"])
        XCTAssertEqual(store.deleted.first?.span, .future)
        let remaining = try await store.event("event-standup")
        XCTAssertNil(remaining)
    }

    func testDeleteRefusesAnEventFromAnotherCalendar() async throws {
        let result = try await call("delete", ["calendar": work.id, "event": "event-secret"])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertTrue(store.deleted.isEmpty)
    }

    func testAWriteStopsWhenTheCalendarIsUnassignedMidCall() async throws {
        // The broker reads the assignments again at the provider's checkpoint. Unassigning
        // between the two reads must stop the write, not report it after it happened.
        let granted = Granted(first: [work.id], then: [])
        let request = ToolBridgeRequest(session: "s", action: .call, provider: "calendar", tool: "create",
                                        arguments: try JSONSerialization.data(withJSONObject: [
                                            "calendar": work.id, "title": "Late", "start": "2027-02-01T10:00:00Z"]))
        await XCTAssertThrowsErrorAsync(try await ToolBroker.perform(
            request, registry: registry, assignments: { ["calendar": granted.next()] },
            context: ToolCallContext(agentID: agent, workspace: URL(fileURLWithPath: "/"))))
        XCTAssertTrue(store.created.isEmpty, "the checkpoint must stop the write, not report it afterwards")
    }
    private final class Granted: @unchecked Sendable {
        private let lock = NSLock(); private var remaining: [Set<String>]
        init(first: Set<String>, then rest: Set<String>) { remaining = [first, rest] }
        func next() -> Set<String> { lock.withLock { remaining.count > 1 ? remaining.removeFirst() : remaining[0] } }
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("Expected an error", file: file, line: line) } catch {}
}
