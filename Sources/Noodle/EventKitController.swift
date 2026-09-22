import AppKit
import EventKit
import Foundation
import NoodleCalendarTools
import NoodleCore
import NoodleRemindersTools
import Observation
import SwiftUI

/// EventKit for the Calendar and Reminders tools. macOS grants this access to Noodle
/// itself and never to a background extension, so these providers run in the app and
/// these stores are the only places that touch the person's calendars and reminders.
actor EventKitCalendarStore: CalendarStore {
    /// Built on first use: making one loads EventKit's stores, which nothing needs until
    /// a bot calls a tool or the Calendars tab opens.
    private lazy var store = EKEventStore()

    /// Occurrences of a repeating event share one EventKit identifier, so a listed event
    /// carries the occurrence's start and resolves back to that occurrence.
    private static func compose(_ identifier: String, start: Date, recurring: Bool) -> String {
        recurring ? "\(identifier)#\(ToolDates.string(start))" : identifier
    }

    private func resolve(_ id: String) throws -> EKEvent {
        let parts = id.split(separator: "#", maxSplits: 1)
        guard let base = store.event(withIdentifier: String(parts[0])) else {
            throw ToolProviderError("There is no event with ID \(id).")
        }
        guard parts.count == 2, let start = ToolDates.parse(String(parts[1]))?.date, let calendar = base.calendar else { return base }
        let window = store.predicateForEvents(withStart: start.addingTimeInterval(-60), end: start.addingTimeInterval(60), calendars: [calendar])
        return store.events(matching: window).first {
            $0.eventIdentifier == base.eventIdentifier && abs($0.startDate.timeIntervalSince(start)) < 1
        } ?? base
    }

    private func record(_ event: EKEvent) -> CalendarEventRecord {
        CalendarEventRecord(
            id: Self.compose(event.eventIdentifier ?? "", start: event.startDate, recurring: event.hasRecurrenceRules),
            calendarID: event.calendar?.calendarIdentifier ?? "", title: event.title ?? "",
            start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
            location: event.location, notes: event.notes, url: event.url, isRecurring: event.hasRecurrenceRules)
    }

    private func authorized() throws {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw ToolProviderError("Noodle does not have access to this Mac's calendars. Allow it in System Settings, Privacy & Security, Calendars.")
        }
    }

    private func resolveCalendar(_ id: String) throws -> EKCalendar {
        try authorized()
        guard let calendar = store.calendar(withIdentifier: id) else { throw ToolProviderError("That calendar is no longer on this Mac.") }
        return calendar
    }

    func calendars() async throws -> [EventKitList] {
        try authorized()
        return store.calendars(for: .event).map(EventKitLists.describe)
    }

    func events(in calendar: String, from: Date, to: Date, query: String?, limit: Int) async throws -> [CalendarEventRecord] {
        let calendar = try resolveCalendar(calendar)
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: [calendar])
        let matches = store.events(matching: predicate).filter { event in
            guard let query, !query.isEmpty else { return true }
            return [event.title, event.location, event.notes].compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
        return matches.sorted { $0.startDate < $1.startDate }.prefix(limit).map(record)
    }

    func event(_ id: String) async throws -> CalendarEventRecord? {
        try authorized()
        return try? record(resolve(id))
    }

    func create(in calendar: String, draft: CalendarEventDraft) async throws -> CalendarEventRecord {
        let calendar = try resolveCalendar(calendar)
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        apply(draft, to: event)
        try store.save(event, span: .thisEvent, commit: true)
        return record(event)
    }

    func update(_ id: String, draft: CalendarEventDraft, span: CalendarSpan) async throws -> CalendarEventRecord {
        try authorized()
        let event = try resolve(id)
        apply(draft, to: event)
        try store.save(event, span: span == .future ? .futureEvents : .thisEvent, commit: true)
        return record(event)
    }

    func delete(_ id: String, span: CalendarSpan) async throws {
        try authorized()
        try store.remove(try resolve(id), span: span == .future ? .futureEvents : .thisEvent, commit: true)
    }

    private func apply(_ draft: CalendarEventDraft, to event: EKEvent) {
        if let title = draft.title { event.title = title }
        if let allDay = draft.isAllDay { event.isAllDay = allDay }
        if let start = draft.start { event.startDate = start }
        if let end = draft.end { event.endDate = end }
        if let location = draft.location { event.location = location }
        if let notes = draft.notes { event.notes = notes }
        if let url = draft.url { event.url = url }
    }
}

actor EventKitReminderStore: ReminderStore {
    private lazy var store = EKEventStore()

    private func authorized() throws {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            throw ToolProviderError("Noodle does not have access to this Mac's reminders. Allow it in System Settings, Privacy & Security, Reminders.")
        }
    }

    private func resolveList(_ id: String) throws -> EKCalendar {
        try authorized()
        guard let list = store.calendar(withIdentifier: id) else { throw ToolProviderError("That reminder list is no longer on this Mac.") }
        return list
    }

    private func resolve(_ id: String) throws -> EKReminder {
        try authorized()
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ToolProviderError("There is no reminder with ID \(id).")
        }
        return reminder
    }

    /// EventKit has no async fetch for reminders, only this callback, so the records are
    /// built before the continuation resumes and no EventKit object crosses the boundary.
    private func fetch(_ predicate: NSPredicate) async -> [ReminderRecord] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map(EventKitLists.record))
            }
        }
    }

    func lists() async throws -> [EventKitList] {
        try authorized()
        return store.calendars(for: .reminder).map(EventKitLists.describe)
    }

    func reminders(in list: String, completed: Bool?, dueBefore: Date?, dueAfter: Date?, query: String?, limit: Int) async throws -> [ReminderRecord] {
        let list = try resolveList(list)
        let predicate = switch completed {
        case true: store.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: [list])
        case false: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [list])
        default: store.predicateForReminders(in: [list])
        }
        let matches = await fetch(predicate).filter { reminder in
            if let dueAfter, reminder.due.map({ $0 <= dueAfter }) ?? true { return false }
            if let dueBefore, reminder.due.map({ $0 >= dueBefore }) ?? true { return false }
            guard let query, !query.isEmpty else { return true }
            return [reminder.title, reminder.notes].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(query) }
        }
        // Soonest first, and anything without a date after what is dated.
        return matches.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }.prefix(limit).map { $0 }
    }

    func reminder(_ id: String) async throws -> ReminderRecord? {
        try authorized()
        return (store.calendarItem(withIdentifier: id) as? EKReminder).map(EventKitLists.record)
    }

    func create(in list: String, draft: ReminderDraft) async throws -> ReminderRecord {
        let list = try resolveList(list)
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        apply(draft, to: reminder)
        try store.save(reminder, commit: true)
        return EventKitLists.record(reminder)
    }

    func update(_ id: String, draft: ReminderDraft) async throws -> ReminderRecord {
        let reminder = try resolve(id)
        apply(draft, to: reminder)
        try store.save(reminder, commit: true)
        return EventKitLists.record(reminder)
    }

    func delete(_ id: String) async throws {
        try store.remove(try resolve(id), commit: true)
    }

    private func apply(_ draft: ReminderDraft, to reminder: EKReminder) {
        if let title = draft.title { reminder.title = title }
        if let notes = draft.notes { reminder.notes = notes }
        if let url = draft.url { reminder.url = url }
        if let priority = draft.priority { reminder.priority = priority }
        if let completed = draft.completed { reminder.isCompleted = completed }
        if draft.clearsDue {
            reminder.dueDateComponents = nil
        } else if let due = draft.due {
            let fields: Set<Calendar.Component> = draft.dueHasTime == true
                ? [.year, .month, .day, .hour, .minute, .second] : [.year, .month, .day]
            reminder.dueDateComponents = Calendar.current.dateComponents(fields, from: due)
        }
    }
}

/// Shared conversions between EventKit and what the tool providers speak.
enum EventKitLists {
    static func describe(_ calendar: EKCalendar) -> EventKitList {
        EventKitList(id: calendar.calendarIdentifier, title: calendar.title, source: calendar.source?.title ?? "",
                     writable: calendar.allowsContentModifications, colour: calendar.cgColor.map(EventKitColour.packed))
    }

    static func record(_ reminder: EKReminder) -> ReminderRecord {
        let components = reminder.dueDateComponents
        return ReminderRecord(id: reminder.calendarItemIdentifier, listID: reminder.calendar?.calendarIdentifier ?? "",
                       title: reminder.title ?? "", notes: reminder.notes, url: reminder.url,
                       due: components.flatMap { Calendar.current.date(from: $0) },
                       dueHasTime: components?.hour != nil,
                       completed: reminder.isCompleted, completedAt: reminder.completionDate,
                       priority: reminder.priority, isRecurring: reminder.hasRecurrenceRules)
    }
}

/// A calendar's colour, kept as one packed 0xRRGGBB value so it survives a round trip
/// through the assignments file.
enum EventKitColour {
    static func packed(_ colour: CGColor) -> Int {
        guard let rgb = colour.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let components = rgb.components, components.count >= 3 else { return 0 }
        let channel: (CGFloat) -> Int = { Int((min(max($0, 0), 1) * 255).rounded()) }
        return channel(components[0]) << 16 | channel(components[1]) << 8 | channel(components[2])
    }
    static func colour(_ packed: Int?) -> Color {
        guard let packed else { return .secondary }
        return Color(.sRGB, red: Double((packed >> 16) & 0xFF) / 255, green: Double((packed >> 8) & 0xFF) / 255,
                     blue: Double(packed & 0xFF) / 255)
    }
}

/// Calendars and reminder lists are assigned the same way, so one controller serves both:
/// only the EventKit entity, the file and the wording differ.
@MainActor @Observable final class EventKitController {
    enum Access: Equatable { case notDetermined, denied, granted }
    let kind: EventKitAssignments.Kind
    private(set) var registry = EventKitAssignments()
    /// Nil until something asks: reading the status loads EventKit, and nothing needs it
    /// before the tab opens or a bot calls a tool.
    private(set) var access: Access?
    private(set) var failure: String?
    private(set) var requesting = false
    @ObservationIgnored private let repository: WorkspaceRepository
    @ObservationIgnored private let lister: @Sendable () async throws -> [EventKitList]
    @ObservationIgnored private var readable = true
    /// Receives each agent's assigned IDs for the tool broker, now and on every change.
    @ObservationIgnored var onAssignmentsChange: (([UUID: Set<String>]) -> Void)? { didSet { publishAssignments() } }
    private func publishAssignments() { onAssignmentsChange?(registry.toolAssignments(readable: readable)) }

    init(repository: WorkspaceRepository, kind: EventKitAssignments.Kind,
         lister: @escaping @Sendable () async throws -> [EventKitList]) {
        self.repository = repository
        self.kind = kind
        self.lister = lister
        do { registry = try EventKitAssignments.load(root: repository.rootURL, kind: kind) }
        catch { readable = false; failure = error.localizedDescription }
    }

    private var entity: EKEntityType { kind == .calendar ? .event : .reminder }

    private func status() -> Access {
        switch EKEventStore.authorizationStatus(for: entity) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func selectedIDs(for agent: AgentRecord) -> Set<String> { registry.assigned(to: agent.id) }

    func validate(_ ids: Set<String>) throws {
        guard readable, ids.isSubset(of: Set(registry.lists.map(\.id))) else {
            throw ToolProviderError("One of the selected \(kind.noun)s is no longer on this Mac.")
        }
    }

    func assign(_ ids: Set<String>, to agent: AgentRecord, synchronizeWorkspace: Bool = true) throws {
        try validate(ids)
        var next = registry; next.agents[agent.id.uuidString] = ids
        try next.save(root: repository.rootURL, kind: kind); registry = next
        publishAssignments()
        if synchronizeWorkspace { try repository.synchronizeAgentWorkspace(agent) }
    }

    func reloadAssignments() throws {
        defer { publishAssignments() }
        do { registry = try EventKitAssignments.load(root: repository.rootURL, kind: kind); readable = true }
        catch { readable = false; throw error }
    }

    /// Asks macOS for access. Only the app can: the prompt names Noodle.
    func requestAccess() async {
        guard !requesting, access != .granted else { return }
        requesting = true
        defer { requesting = false }
        do {
            let store = EKEventStore()
            _ = kind == .calendar ? try await store.requestFullAccessToEvents() : try await store.requestFullAccessToReminders()
            failure = nil
        } catch { failure = error.localizedDescription }
        access = status()
        await refresh()
    }

    func openPrivacySettings() {
        let pane = kind == .calendar ? "Privacy_Calendars" : "Privacy_Reminders"
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Keeps the catalogue shown in Settings in step with what is on this Mac.
    func refresh() async {
        access = status()
        guard access == .granted else { return }
        do {
            let lists = try await lister()
            guard readable, registry.lists != lists else { return }
            var next = registry
            next.lists = lists
            // Something that is gone cannot stay assigned to anyone.
            let known = Set(lists.map(\.id))
            next.agents = next.agents.mapValues { $0.intersection(known) }
            try next.save(root: repository.rootURL, kind: kind)
            registry = next
            publishAssignments()
            failure = nil
        } catch { failure = error.localizedDescription }
    }
}

struct EventKitAssignmentPicker: View {
    let controller: EventKitController
    @Binding var selectedIDs: Set<String>

    private var lists: [EventKitList] { controller.registry.lists.sorted { $0.title < $1.title } }
    private var isCalendar: Bool { controller.kind == .calendar }
    private var title: String { isCalendar ? "Calendars" : "Reminder Lists" }
    private var symbol: String { isCalendar ? "calendar" : "checklist" }
    private var privacyPane: String { isCalendar ? "Calendars" : "Reminders" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.caption.weight(.semibold))
            switch controller.access {
            case nil:
                message("Checking access…", detail: "")
            case .granted where lists.isEmpty:
                message(isCalendar ? "No calendars on this Mac yet." : "No reminder lists on this Mac yet.",
                        detail: isCalendar ? "Add one in Calendar, then come back." : "Add one in Reminders, then come back.")
            case .granted:
                Text("This bot can read and change the \(controller.kind.noun)s you select here, and no others.")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(lists) { list in row(list) }
                    }
                }
            case .notDetermined:
                message("Noodle has not asked for your \(privacyPane.lowercased()) yet.",
                        detail: "Allowing access lets you give a bot the \(controller.kind.noun)s you choose.") {
                    Button(controller.requesting ? "Asking…" : "Allow \(privacyPane) Access…") {
                        Task { await controller.requestAccess() }
                    }.disabled(controller.requesting)
                }
            case .denied:
                message("Noodle does not have access to your \(privacyPane.lowercased()).",
                        detail: "Turn on \(privacyPane) for Noodle in System Settings, then come back.") {
                    Button("Open Privacy Settings") { controller.openPrivacySettings() }
                }
            }
            if let failure = controller.failure {
                Text(failure).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minHeight: 220, alignment: .top)
        .task { await controller.refresh() }
    }

    private func row(_ list: EventKitList) -> some View {
        Toggle(isOn: Binding(
            get: { selectedIDs.contains(list.id) },
            set: { selected in
                if selected { selectedIDs.insert(list.id) } else { selectedIDs.remove(list.id) }
            }
        )) {
            HStack(spacing: 8) {
                Image(systemName: "circle.fill").font(.system(size: 9)).foregroundStyle(EventKitColour.colour(list.colour))
                VStack(alignment: .leading, spacing: 1) {
                    Text(list.title)
                    Text(list.writable ? list.source : "\(list.source) · read-only")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 4)
    }

    @ViewBuilder private func message(_ title: String, detail: String, @ViewBuilder action: () -> some View = { EmptyView() }) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.largeTitle)
            Text(title)
            if !detail.isEmpty { Text(detail).font(.caption).multilineTextAlignment(.center) }
            action()
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 12)
    }
}
