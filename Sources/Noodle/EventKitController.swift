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
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return
        // EventKit keeps reporting `notDetermined` for reminders long after it has
        // granted the access, so lists it will hand over are the better answer.
        case .notDetermined where !store.calendars(for: .reminder).isEmpty: return
        default:
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
    /// What macOS answers when asked, and what it answers when told to ask the person.
    /// Injectable so the states EventKit reaches on a real Mac can be tested without one.
    @ObservationIgnored private let probe: @MainActor () -> Access
    @ObservationIgnored private let requester: @Sendable () async throws -> Bool
    @ObservationIgnored private var readable = true
    /// Receives each agent's assigned IDs for the tool broker, now and on every change.
    @ObservationIgnored var onAssignmentsChange: (([UUID: Set<String>]) -> Void)? { didSet { publishAssignments() } }
    private func publishAssignments() { onAssignmentsChange?(registry.toolAssignments(readable: readable)) }

    init(repository: WorkspaceRepository, kind: EventKitAssignments.Kind,
         status: (@MainActor () -> Access)? = nil,
         request: (@Sendable () async throws -> Bool)? = nil,
         lister: @escaping @Sendable () async throws -> [EventKitList]) {
        self.repository = repository
        self.kind = kind
        self.lister = lister
        let entity: EKEntityType = kind == .calendar ? .event : .reminder
        probe = status ?? { Self.status(of: entity) }
        requester = request ?? {
            let store = EKEventStore()
            return kind == .calendar ? try await store.requestFullAccessToEvents() : try await store.requestFullAccessToReminders()
        }
        do { registry = try EventKitAssignments.load(root: repository.rootURL, kind: kind) }
        catch { readable = false; failure = error.localizedDescription }
    }

    private static func status(of entity: EKEntityType) -> Access {
        switch EKEventStore.authorizationStatus(for: entity) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// EventKit keeps answering `notDetermined` for reminders after it has already
    /// granted the access, so a grant this app has seen outranks that answer. Anything
    /// else it says, a withdrawal included, still stands.
    private func observe(_ probed: Access) {
        guard probed == .notDetermined, access == .granted else { access = probed; return }
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
        var granted = false, refused: String?
        do { granted = try await requester(); failure = nil }
        catch { refused = error.localizedDescription; failure = refused }
        // The request itself is the answer. Asking again can contradict it.
        if granted { access = .granted } else { observe(probe()) }
        await refresh()
        // A request that failed says something the picker cannot work out on its own,
        // so it survives the refresh that follows it.
        if let refused { failure = refused }
    }

    func openPrivacySettings() {
        let pane = kind == .calendar ? "Privacy_Calendars" : "Privacy_Reminders"
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Keeps the catalogue shown in Settings in step with what is on this Mac.
    func refresh() async {
        observe(probe())
        // Access the person has not given is a state the picker explains, never a failure.
        guard access == .granted else { failure = nil; return }
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

/// Noodle's own tools carry the same weight in a list as a connection's app icon.
struct EventKitToolIcon: View {
    let symbol: String
    let size: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.22)
            .fill(.tint.opacity(0.18))
            .overlay {
                Image(systemName: symbol).font(.system(size: size * 0.62, weight: .medium)).foregroundStyle(.tint)
            }
            .frame(width: size, height: size)
    }
}

/// Calendars and Reminders are tools a bot is given like any other. The row carries the
/// scope: which calendars or lists, chosen behind its own button.
struct EventKitToolRow: View {
    let controller: EventKitController
    @Binding var selectedIDs: Set<String>
    let onRemove: () -> Void
    @State private var showingScope = false

    private var isCalendar: Bool { controller.kind == .calendar }
    var title: String { isCalendar ? "Calendar" : "Reminders" }
    private var symbol: String { isCalendar ? "calendar" : "checklist" }
    private var chosen: [EventKitList] {
        controller.registry.lists.filter { selectedIDs.contains($0.id) }.sorted { $0.title < $1.title }
    }
    /// What the row says under its name: the chosen lists, or what is in the way.
    private var summary: String {
        switch controller.access {
        case .denied: "No access — choose \(title) in System Settings"
        case .notDetermined: "Allow access to choose \(controller.kind.noun)s"
        case nil: "Checking access…"
        case .granted where chosen.isEmpty: "No \(controller.kind.noun)s chosen yet"
        case .granted: chosen.map(\.title).joined(separator: ", ")
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            EventKitToolIcon(symbol: symbol, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { showingScope = true } label: { Image(systemName: "ellipsis.circle").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .help("Choose which \(controller.kind.noun)s this bot may use")
                .popover(isPresented: $showingScope, arrowEdge: .bottom) { scope }
            Button(action: onRemove) { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain).help("Remove \(title) from this bot")
        }
        .padding(8)
        .task { await controller.refresh() }
    }

    @ViewBuilder private var scope: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch controller.access {
            case .granted where controller.registry.lists.isEmpty:
                Text("No \(controller.kind.noun)s on this Mac yet.").foregroundStyle(.secondary)
            case .granted:
                Text("This bot may use:").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(controller.registry.lists.sorted { $0.title < $1.title }) { list in
                            Toggle(isOn: Binding(
                                get: { selectedIDs.contains(list.id) },
                                set: { on in
                                    if on { selectedIDs.insert(list.id) } else { selectedIDs.remove(list.id) }
                                }
                            )) {
                                HStack(spacing: 8) {
                                    Image(systemName: "circle.fill").font(.system(size: 9))
                                        .foregroundStyle(EventKitColour.colour(list.colour))
                                    Text(list.title)
                                    if !list.writable {
                                        Text("read-only").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }.toggleStyle(.checkbox)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            case .notDetermined:
                Text("Noodle needs access to this Mac's \(title.lowercased()) before you can choose.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { Task { await controller.requestAccess() } } label: {
                    Label(controller.requesting ? "Asking…" : "Allow Access…", systemImage: "lock.open")
                }.disabled(controller.requesting)
            case .denied:
                Text("Turn \(title) on for Noodle in System Settings, then come back.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { controller.openPrivacySettings() } label: { Label("Open Settings…", systemImage: "gear") }
            case nil:
                Text("Checking access…").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack { Spacer(); Button("Done") { showingScope = false } }
        }.padding(14).frame(width: 260, height: 240)
    }
}
