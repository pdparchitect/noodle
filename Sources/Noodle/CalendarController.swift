import AppKit
import EventKit
import Foundation
import NoodleCalendarTools
import NoodleCore
import Observation
import SwiftUI

/// EventKit for the Calendar tools. macOS grants calendar access to Noodle itself and
/// never to a background extension, so this provider runs in the app and this store is
/// the only place that touches the person's calendars.
actor EventKitCalendarStore: CalendarStore {
    /// Built on first use: making one loads EventKit's stores, which nothing needs until
    /// a bot calls a tool or the Calendars tab opens.
    private lazy var store = EKEventStore()
    private static let identifier = ISO8601DateFormatter()

    /// Occurrences of a repeating event share one EventKit identifier, so a listed event
    /// carries the occurrence's start and resolves back to that occurrence.
    private static func compose(_ identifier: String, start: Date, recurring: Bool) -> String {
        recurring ? "\(identifier)#\(Self.identifier.string(from: start))" : identifier
    }

    private func resolve(_ id: String) throws -> EKEvent {
        let parts = id.split(separator: "#", maxSplits: 1)
        guard let base = store.event(withIdentifier: String(parts[0])) else {
            throw ToolProviderError("There is no event with ID \(id).")
        }
        guard parts.count == 2, let start = Self.identifier.date(from: String(parts[1])), let calendar = base.calendar else { return base }
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

    func calendars() async throws -> [CalendarRecord] {
        try authorized()
        return store.calendars(for: .event).map {
            CalendarRecord(id: $0.calendarIdentifier, title: $0.title, source: $0.source?.title ?? "",
                           writable: $0.allowsContentModifications, colour: $0.cgColor.map(CalendarColour.packed))
        }
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

/// A calendar's colour, kept as one packed 0xRRGGBB value so it survives a round trip
/// through the assignments file.
enum CalendarColour {
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

@MainActor @Observable final class CalendarController {
    enum Access: Equatable { case notDetermined, denied, granted }
    private(set) var registry = CalendarAssignments()
    /// Nil until something asks: reading the status loads EventKit, and nothing needs it
    /// before the Calendars tab opens or a bot calls a tool.
    private(set) var access: Access?
    private(set) var failure: String?
    private(set) var requesting = false
    @ObservationIgnored let toolStore: any CalendarStore
    @ObservationIgnored private let repository: WorkspaceRepository
    @ObservationIgnored private var readable = true
    /// Receives each agent's assigned calendar IDs for the tool broker, now and on every change.
    @ObservationIgnored var onAssignmentsChange: (([UUID: Set<String>]) -> Void)? { didSet { publishAssignments() } }
    private func publishAssignments() { onAssignmentsChange?(registry.toolAssignments(readable: readable)) }

    init(repository: WorkspaceRepository, store: (any CalendarStore)? = nil) {
        self.repository = repository
        toolStore = store ?? EventKitCalendarStore()
        do { registry = try CalendarAssignments.load(root: repository.rootURL) }
        catch { readable = false; failure = error.localizedDescription }
    }

    private static func status() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func selectedIDs(for agent: AgentRecord) -> Set<String> { registry.assigned(to: agent.id) }

    func validate(_ ids: Set<String>) throws {
        guard readable, ids.isSubset(of: Set(registry.calendars.map(\.id))) else {
            throw ToolProviderError("One of the selected calendars is no longer on this Mac.")
        }
    }

    func assign(_ ids: Set<String>, to agent: AgentRecord, synchronizeWorkspace: Bool = true) throws {
        try validate(ids)
        var next = registry; next.agents[agent.id.uuidString] = ids
        try next.save(root: repository.rootURL); registry = next
        publishAssignments()
        if synchronizeWorkspace { try repository.synchronizeAgentWorkspace(agent) }
    }

    func reloadAssignments() throws {
        defer { publishAssignments() }
        do { registry = try CalendarAssignments.load(root: repository.rootURL); readable = true }
        catch { readable = false; throw error }
    }

    /// Asks macOS for calendar access. Only the app can: the prompt names Noodle.
    func requestAccess() async {
        guard !requesting, access != .granted else { return }
        _ = Self.status()
        requesting = true
        defer { requesting = false }
        do {
            _ = try await EKEventStore().requestFullAccessToEvents()
            failure = nil
        } catch { failure = error.localizedDescription }
        access = Self.status()
        await refresh()
    }

    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Keeps the catalogue shown in Settings in step with the calendars on this Mac.
    func refresh() async {
        access = Self.status()
        guard access == .granted else { return }
        do {
            let calendars = try await toolStore.calendars()
            guard readable, registry.calendars != calendars else { return }
            var next = registry
            next.calendars = calendars
            // A calendar that is gone cannot stay assigned to anyone.
            let known = Set(calendars.map(\.id))
            next.agents = next.agents.mapValues { $0.intersection(known) }
            try next.save(root: repository.rootURL)
            registry = next
            publishAssignments()
            failure = nil
        } catch { failure = error.localizedDescription }
    }
}

struct CalendarAssignmentPicker: View {
    let controller: CalendarController
    @Binding var selectedIDs: Set<String>

    private var calendars: [CalendarRecord] { controller.registry.calendars.sorted { $0.title < $1.title } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Calendars").font(.caption.weight(.semibold))
            switch controller.access {
            case nil:
                message("Checking calendar access…", detail: "")
            case .granted where calendars.isEmpty:
                message("No calendars on this Mac yet.", detail: "Add one in Calendar, then come back.")
            case .granted:
                Text("This bot can read and change the calendars you select here, and no others.")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(calendars) { calendar in row(calendar) }
                    }
                }
            case .notDetermined:
                message("Noodle has not asked for your calendars yet.",
                        detail: "Allowing access lets you give a bot the calendars you choose.") {
                    Button(controller.requesting ? "Asking…" : "Allow Calendar Access…") {
                        Task { await controller.requestAccess() }
                    }.disabled(controller.requesting)
                }
            case .denied:
                message("Noodle does not have calendar access.",
                        detail: "Turn on Calendars for Noodle in System Settings, then come back.") {
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

    private func row(_ calendar: CalendarRecord) -> some View {
        Toggle(isOn: Binding(
            get: { selectedIDs.contains(calendar.id) },
            set: { selected in
                if selected { selectedIDs.insert(calendar.id) } else { selectedIDs.remove(calendar.id) }
            }
        )) {
            HStack(spacing: 8) {
                Image(systemName: "circle.fill").font(.system(size: 9)).foregroundStyle(CalendarColour.colour(calendar.colour))
                VStack(alignment: .leading, spacing: 1) {
                    Text(calendar.title)
                    Text(calendar.writable ? calendar.source : "\(calendar.source) · read-only")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 4)
    }

    @ViewBuilder private func message(_ title: String, detail: String, @ViewBuilder action: () -> some View = { EmptyView() }) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar").font(.largeTitle)
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
