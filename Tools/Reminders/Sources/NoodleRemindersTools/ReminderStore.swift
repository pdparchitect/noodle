import Foundation
import NoodleCore

public struct ReminderRecord: Sendable, Equatable {
    public var id: String
    public var listID: String
    public var title: String
    public var notes: String?
    public var url: URL?
    public var due: Date?
    /// A reminder due on a day carries no time; one due at a moment does.
    public var dueHasTime: Bool
    public var completed: Bool
    public var completedAt: Date?
    /// EventKit's scale: 0 none, 1–4 high, 5 medium, 6–9 low.
    public var priority: Int
    public var isRecurring: Bool
    public init(id: String, listID: String, title: String, notes: String? = nil, url: URL? = nil, due: Date? = nil,
                dueHasTime: Bool = false, completed: Bool = false, completedAt: Date? = nil, priority: Int = 0,
                isRecurring: Bool = false) {
        self.id = id; self.listID = listID; self.title = title; self.notes = notes; self.url = url; self.due = due
        self.dueHasTime = dueHasTime; self.completed = completed; self.completedAt = completedAt
        self.priority = priority; self.isRecurring = isRecurring
    }
}

/// What a create or update changes. Nil leaves the stored value alone; a due date is
/// removed only through `clearsDue`, so "no date given" never silently clears one.
public struct ReminderDraft: Sendable, Equatable {
    public var title: String?
    public var notes: String?
    public var url: URL?
    public var due: Date?
    public var dueHasTime: Bool?
    public var clearsDue = false
    public var completed: Bool?
    public var priority: Int?
    public init() {}
}

/// The reminder lists themselves. Noodle implements this with EventKit; tests use their own.
public protocol ReminderStore: Sendable {
    func lists() async throws -> [EventKitList]
    func reminders(in list: String, completed: Bool?, dueBefore: Date?, dueAfter: Date?, query: String?, limit: Int) async throws -> [ReminderRecord]
    func reminder(_ id: String) async throws -> ReminderRecord?
    func create(in list: String, draft: ReminderDraft) async throws -> ReminderRecord
    func update(_ id: String, draft: ReminderDraft) async throws -> ReminderRecord
    func delete(_ id: String) async throws
}
