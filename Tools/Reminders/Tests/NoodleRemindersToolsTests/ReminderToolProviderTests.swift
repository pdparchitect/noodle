import NoodleCore
import XCTest
@testable import NoodleRemindersTools

final class ReminderToolProviderTests: XCTestCase {
    private let chores = EventKitList(id: "11111111-1111-1111-1111-111111111111", title: "Chores", source: "iCloud", writable: true)
    private let family = EventKitList(id: "22222222-2222-2222-2222-222222222222", title: "Family", source: "iCloud", writable: true)
    private let shared = EventKitList(id: "33333333-3333-3333-3333-333333333333", title: "Team", source: "Subscribed", writable: false)
    private let agent = UUID()
    private var store: FakeReminders!
    private var provider: ReminderToolProvider!
    private let registry = ToolProviderRegistry()
    private let due = Date(timeIntervalSince1970: 1_800_000_000)

    /// Stands in for EventKit so these tests need no reminder access, no account and no UI.
    private final class FakeReminders: ReminderStore, @unchecked Sendable {
        private let lock = NSLock()
        private var state: (lists: [EventKitList], reminders: [ReminderRecord]) = ([], [])
        private(set) var queries: [(list: String, completed: Bool?, dueBefore: Date?, dueAfter: Date?, query: String?, limit: Int)] = []
        private(set) var created: [(list: String, draft: ReminderDraft)] = []
        private(set) var updated: [(id: String, draft: ReminderDraft)] = []
        private(set) var deleted: [String] = []

        init(lists: [EventKitList], reminders: [ReminderRecord]) { state = (lists, reminders) }
        func lists() async throws -> [EventKitList] { lock.withLock { state.lists } }
        func reminders(in list: String, completed: Bool?, dueBefore: Date?, dueAfter: Date?, query: String?, limit: Int) async throws -> [ReminderRecord] {
            lock.withLock {
                queries.append((list, completed, dueBefore, dueAfter, query, limit))
                return state.reminders.filter { $0.listID == list && (completed == nil || $0.completed == completed) }
            }
        }
        func reminder(_ id: String) async throws -> ReminderRecord? { lock.withLock { state.reminders.first { $0.id == id } } }
        func create(in list: String, draft: ReminderDraft) async throws -> ReminderRecord {
            lock.withLock {
                created.append((list, draft))
                let reminder = ReminderRecord(id: "new-reminder", listID: list, title: draft.title ?? "", notes: draft.notes,
                                              due: draft.due, dueHasTime: draft.dueHasTime ?? false,
                                              completed: draft.completed ?? false, priority: draft.priority ?? 0)
                state.reminders.append(reminder)
                return reminder
            }
        }
        func update(_ id: String, draft: ReminderDraft) async throws -> ReminderRecord {
            try lock.withLock {
                updated.append((id, draft))
                guard let index = state.reminders.firstIndex(where: { $0.id == id }) else { throw ToolProviderError("No such reminder.") }
                if let title = draft.title { state.reminders[index].title = title }
                if let completed = draft.completed { state.reminders[index].completed = completed }
                if draft.clearsDue { state.reminders[index].due = nil } else if let date = draft.due { state.reminders[index].due = date }
                return state.reminders[index]
            }
        }
        func delete(_ id: String) async throws {
            lock.withLock { deleted.append(id); state.reminders.removeAll { $0.id == id } }
        }
    }

    override func setUpWithError() throws {
        store = FakeReminders(lists: [chores, family, shared], reminders: [
            ReminderRecord(id: "reminder-bins", listID: chores.id, title: "Put the bins out", due: due, dueHasTime: true),
            ReminderRecord(id: "reminder-done", listID: chores.id, title: "Book the plumber", completed: true),
            ReminderRecord(id: "reminder-secret", listID: family.id, title: "Buy the present")
        ])
        provider = ReminderToolProvider(store: store)
        try registry.register(provider)
    }

    private func call(_ tool: String, _ arguments: [String: Any], assigned: Set<String>? = nil) async throws -> [String: Any] {
        let request = ToolBridgeRequest(session: "s", action: .call, provider: "reminders", tool: tool,
                                        arguments: try JSONSerialization.data(withJSONObject: arguments))
        let granted = assigned ?? [chores.id]
        let data = try await ToolBroker.perform(request, registry: registry, assignments: { ["reminder-list": granted] },
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
        XCTAssertEqual(provider.manifest.id, "reminders")
        XCTAssertEqual(provider.kind, .builtIn)
        XCTAssertEqual(provider.manifest.activation, .whenAssigned("reminder-list"))
        let context = ToolCallContext(agentID: agent, workspace: URL(fileURLWithPath: "/"))
        let tools = try ToolDescriptor.list(mcp: try await provider.tools(context: context))
        XCTAssertEqual(tools.map(\.name), ["lists", "reminders", "create", "update", "delete"])
        let lists = try XCTUnwrap(tools.first { $0.name == "lists" })
        XCTAssertEqual(lists.resourceList, ToolResourceList(kind: "reminder-list", path: "lists"))
        XCTAssertTrue(lists.resourceParameters.isEmpty)
        for tool in tools where tool.name != "lists" {
            XCTAssertEqual(tool.resourceParameters, [ToolResourceParameter(name: "list", kind: "reminder-list")], tool.name)
            XCTAssertTrue(tool.required.contains("list"), tool.name)
            XCTAssertFalse(tool.description.isEmpty, tool.name)
        }
        XCTAssertTrue(try XCTUnwrap(tools.first { $0.name == "reminders" }).retryable)
        for name in ["create", "update", "delete"] {
            XCTAssertFalse(try XCTUnwrap(tools.first { $0.name == name }).retryable, "\(name) changes a list, so a timed-out call must not repeat")
        }
    }

    func testListsShowOnlyTheListsAssignedToThisBot() async throws {
        let listed = try structured(await call("lists", [:]))
        let lists = try XCTUnwrap(listed["lists"] as? [[String: Any]])
        XCTAssertEqual(lists.map { $0["id"] as? String }, [chores.id])
        XCTAssertEqual(lists.first?["title"] as? String, "Chores")
    }

    func testAnUnassignedListIsRefusedBeforeTheStoreIsTouched() async throws {
        do { _ = try await call("reminders", ["list": family.id]); XCTFail("Expected a refusal.") } catch {}
        XCTAssertTrue(store.queries.isEmpty)
    }

    func testRemindersDefaultToWhatIsStillOpen() async throws {
        let structured = try structured(await call("reminders", ["list": chores.id]))
        let reminders = try XCTUnwrap(structured["reminders"] as? [[String: Any]])
        XCTAssertEqual(reminders.map { $0["title"] as? String }, ["Put the bins out"])
        let query = try XCTUnwrap(store.queries.first)
        XCTAssertEqual(query.list, chores.id)
        XCTAssertEqual(query.completed, false, "a bot asking for reminders means the ones still to do")
    }

    func testRemindersPassTheFiltersThroughToTheStore() async throws {
        _ = try structured(await call("reminders", [
            "list": chores.id, "completed": true, "due-before": "2027-01-16T00:00:00Z", "due-after": "2027-01-15T00:00:00Z",
            "query": "bins", "limit": 5]))
        let query = try XCTUnwrap(store.queries.first)
        XCTAssertEqual(query.completed, true)
        XCTAssertEqual(query.query, "bins")
        XCTAssertEqual(query.limit, 5)
        XCTAssertEqual(query.dueAfter, ISO8601DateFormatter().date(from: "2027-01-15T00:00:00Z"))
        XCTAssertEqual(query.dueBefore, ISO8601DateFormatter().date(from: "2027-01-16T00:00:00Z"))
    }

    func testRemindersRefusesAnUnreadableDate() async throws {
        let result = try await call("reminders", ["list": chores.id, "due-before": "whenever"])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertTrue(store.queries.isEmpty)
    }

    func testCreateAuthorizesBeforeWritingAndKeepsADayWithoutATime() async throws {
        let structured = try structured(await call("create", [
            "list": chores.id, "title": "Renew the passport", "due": "2027-03-04", "notes": "Photos first", "priority": "high"]))
        let reminder = try XCTUnwrap(structured["reminder"] as? [String: Any])
        XCTAssertEqual(reminder["id"] as? String, "new-reminder")
        XCTAssertEqual(reminder["list"] as? String, chores.id)
        let created = try XCTUnwrap(store.created.first)
        XCTAssertEqual(store.created.count, 1)
        XCTAssertEqual(created.list, chores.id)
        XCTAssertEqual(created.draft.title, "Renew the passport")
        XCTAssertEqual(created.draft.notes, "Photos first")
        XCTAssertEqual(created.draft.dueHasTime, false, "a plain date is a day, not midnight")
        XCTAssertNotNil(created.draft.due)
        XCTAssertEqual(created.draft.priority, 1)
    }

    func testCreateRefusesAListThatCannotBeChanged() async throws {
        let result = try await call("create", ["list": shared.id, "title": "Nope"], assigned: [shared.id])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertTrue(message(result).lowercased().contains("read-only"), message(result))
        XCTAssertTrue(store.created.isEmpty)
    }

    func testCreateNeedsATitle() async throws {
        do { _ = try await call("create", ["list": chores.id]); XCTFail("Expected a refusal.") } catch {}
        XCTAssertTrue(store.created.isEmpty)
    }

    func testUpdateRefusesAReminderThatLivesInAnotherList() async throws {
        let result = try await call("update", ["list": chores.id, "reminder": "reminder-secret", "completed": true])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertTrue(store.updated.isEmpty, "a reminder in an unassigned list must never be written")
        XCTAssertTrue(message(result).lowercased().contains("list"), message(result))
    }

    func testUpdateTicksAReminderOff() async throws {
        let structured = try structured(await call("update", ["list": chores.id, "reminder": "reminder-bins", "completed": true]))
        XCTAssertEqual((structured["reminder"] as? [String: Any])?["completed"] as? Bool, true)
        let update = try XCTUnwrap(store.updated.first)
        XCTAssertEqual(update.id, "reminder-bins")
        XCTAssertEqual(update.draft.completed, true)
        XCTAssertNil(update.draft.title)
    }

    func testUpdateClearsADueDateOnlyWhenAsked() async throws {
        _ = try structured(await call("update", ["list": chores.id, "reminder": "reminder-bins", "clear-due": true]))
        XCTAssertEqual(store.updated.first?.draft.clearsDue, true)
        let reminder = try await store.reminder("reminder-bins")
        XCTAssertNil(reminder?.due)
    }

    func testUpdateNeedsSomethingToChange() async throws {
        let result = try await call("update", ["list": chores.id, "reminder": "reminder-bins"])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertTrue(store.updated.isEmpty)
    }

    func testDeleteRemovesTheReminder() async throws {
        _ = try structured(await call("delete", ["list": chores.id, "reminder": "reminder-bins"]))
        XCTAssertEqual(store.deleted, ["reminder-bins"])
        let remaining = try await store.reminder("reminder-bins")
        XCTAssertNil(remaining)
    }

    func testDeleteRefusesAReminderFromAnotherList() async throws {
        let result = try await call("delete", ["list": chores.id, "reminder": "reminder-secret"])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertTrue(store.deleted.isEmpty)
    }

    func testAWriteStopsWhenTheListIsUnassignedMidCall() async throws {
        // The broker reads the assignments again at the provider's checkpoint. Unassigning
        // between the two reads must stop the write, not report it after it happened.
        let granted = Granted(first: [chores.id], then: [])
        let request = ToolBridgeRequest(session: "s", action: .call, provider: "reminders", tool: "create",
                                        arguments: try JSONSerialization.data(withJSONObject: ["list": chores.id, "title": "Late"]))
        await XCTAssertThrowsErrorAsync(try await ToolBroker.perform(
            request, registry: registry, assignments: { ["reminder-list": granted.next()] },
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
