import Foundation
import NoodleCore

public enum CalendarSpan: String, Sendable, Equatable { case event, future }

public struct CalendarEventRecord: Sendable, Equatable {
    public var id: String
    public var calendarID: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    public var url: URL?
    public var isRecurring: Bool
    public init(id: String, calendarID: String, title: String, start: Date, end: Date, isAllDay: Bool = false,
                location: String? = nil, notes: String? = nil, url: URL? = nil, isRecurring: Bool = false) {
        self.id = id; self.calendarID = calendarID; self.title = title; self.start = start; self.end = end
        self.isAllDay = isAllDay; self.location = location; self.notes = notes; self.url = url; self.isRecurring = isRecurring
    }
}

/// What a create or update changes. Nil leaves the stored value alone.
public struct CalendarEventDraft: Sendable, Equatable {
    public var title: String?
    public var start: Date?
    public var end: Date?
    public var isAllDay: Bool?
    public var location: String?
    public var notes: String?
    public var url: URL?
    public init() {}
}

/// The calendars themselves. Noodle implements this with EventKit; tests use their own.
public protocol CalendarStore: Sendable {
    func calendars() async throws -> [CalendarRecord]
    func events(in calendar: String, from: Date, to: Date, query: String?, limit: Int) async throws -> [CalendarEventRecord]
    func event(_ id: String) async throws -> CalendarEventRecord?
    func create(in calendar: String, draft: CalendarEventDraft) async throws -> CalendarEventRecord
    func update(_ id: String, draft: CalendarEventDraft, span: CalendarSpan) async throws -> CalendarEventRecord
    func delete(_ id: String, span: CalendarSpan) async throws
}
