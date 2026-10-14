import Darwin
import Foundation

/// A wake a bot scheduled for itself through Messenger, with a note to its future self.
public struct AgentWake: Codable, Hashable, Sendable {
    public let id: UUID
    public let dueAt: Date
    public let note: String
    /// A cron expression for a wake that comes back after firing; nil for a one-off wake.
    public let schedule: String?

    public init(id: UUID = UUID(), dueAt: Date, note: String, schedule: String? = nil) {
        self.id = id; self.dueAt = dueAt; self.note = note; self.schedule = schedule
    }
}

extension AgentWake {
    /// Left for a bot when it is made, so it greets the person before they write.
    public static func introductionNote(in conversationID: UUID) -> String {
        "You were just made. Introduce yourself in conversation \(conversationID): in a few sentences, say who you are, what you are best at and how you can help."
    }
    static let requestNote = "Another bot asked you for help. Run --list-requests and answer each with --answer-request."
    static let answerNote = "A bot answered your request. Run --list-answers and reply in the conversation each request came from."
    /// Noodle's wakes for another bot's request or answer. They take none of the bot's own wakes,
    /// but their turns count towards waking in a row.
    var isFromAnotherBot: Bool { schedule == nil && [Self.requestNote, Self.answerNote].contains(note) }
}

/// A five-field cron expression (minute, hour, day of month, month, day of week) in the
/// Mac's local time, with lists, ranges, steps, month and weekday names and the @ shorthands.
public struct CronSchedule: Sendable {
    private let minutes: [Int], hours: [Int]
    private let days: Set<Int>, months: Set<Int>, weekdays: Set<Int>
    /// As in cron, when both day fields are restricted a day matching either one counts.
    private let eitherDay: Bool

    private static let shorthands = ["@hourly": "0 * * * *", "@daily": "0 0 * * *", "@midnight": "0 0 * * *",
                                     "@weekly": "0 0 * * 0", "@monthly": "0 0 1 * *",
                                     "@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *"]
    private static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let weekdayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    public init?(_ expression: String) {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = (Self.shorthands[trimmed.lowercased()] ?? trimmed).split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5,
              let minutes = Self.values(fields[0], 0...59),
              let hours = Self.values(fields[1], 0...23),
              let days = Self.values(fields[2], 1...31),
              let months = Self.values(fields[3], 1...12, names: Self.monthNames, firstName: 1),
              let weekdays = Self.values(fields[4], 0...7, names: Self.weekdayNames, firstName: 0) else { return nil }
        self.minutes = minutes.sorted(); self.hours = hours.sorted()
        self.days = days; self.months = months
        self.weekdays = Set(weekdays.map { $0 % 7 })
        eitherDay = !fields[2].hasPrefix("*") && !fields[4].hasPrefix("*")
    }

    /// The first matching minute after `date`, or nil when none comes within five years.
    public func nextDate(after date: Date, calendar: Calendar) -> Date? {
        guard let start = calendar.dateInterval(of: .minute, for: date)?.end,
              let firstDay = calendar.dateInterval(of: .day, for: start)?.start else { return nil }
        for offset in 0..<(366 * 5) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay) else { return nil }
            let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            guard let month = parts.month, let dayOfMonth = parts.day, let weekday = parts.weekday,
                  months.contains(month) else { continue }
            let dayMatches = days.contains(dayOfMonth), weekdayMatches = weekdays.contains(weekday - 1)
            guard eitherDay ? dayMatches || weekdayMatches : dayMatches && weekdayMatches else { continue }
            for hour in hours {
                for minute in minutes {
                    let wanted = DateComponents(year: parts.year, month: month, day: dayOfMonth, hour: hour, minute: minute)
                    // Times skipped by a daylight saving change do not happen that day.
                    guard let candidate = calendar.date(from: wanted), candidate >= start,
                          calendar.component(.hour, from: candidate) == hour,
                          calendar.component(.minute, from: candidate) == minute else { continue }
                    return candidate
                }
            }
        }
        return nil
    }

    private static func values(_ field: String, _ range: ClosedRange<Int>, names: [String] = [], firstName: Int = 0) -> Set<Int>? {
        func number(_ raw: Substring) -> Int? {
            if let index = names.firstIndex(of: raw.lowercased()) { return index + firstName }
            guard let value = Int(raw), range.contains(value) else { return nil }
            return value
        }
        var result = Set<Int>()
        for item in field.split(separator: ",", omittingEmptySubsequences: false) {
            let parts = item.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return nil }
            var step = 1
            if parts.count == 2 {
                guard let value = Int(parts[1]), value > 0 else { return nil }
                step = value
            }
            let bounds: ClosedRange<Int>
            if parts[0] == "*" {
                bounds = range
            } else {
                let ends = parts[0].split(separator: "-", omittingEmptySubsequences: false)
                guard ends.count <= 2, let low = number(ends[0]) else { return nil }
                if ends.count == 2 {
                    guard let high = number(ends[1]), low <= high else { return nil }
                    bounds = low...high
                } else {
                    bounds = low...(parts.count == 2 ? range.upperBound : low)
                }
            }
            result.formUnion(stride(from: bounds.lowerBound, through: bounds.upperBound, by: step))
        }
        return result
    }

    /// Wakes follow the clock of the Mac that runs the bot.
    static var localCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }
}

/// What `--list-wakes` returns. `due` holds wakes that fired since the bot last listed them.
public struct AgentWakeList: Codable, Hashable, Sendable {
    public let due: [AgentWake]
    public let pending: [AgentWake]
}

/// Limits that keep a bot waking itself from turning into a loop.
public enum AgentWakeLimits {
    public static let pending = 3
    public static let minimumDelay: TimeInterval = 300
    /// Wakes in a row with no message from anyone else in the bot's conversations.
    public static let withoutOutsideMessages = 12
    public static let noteLength = 1_000
}

struct AgentWakeError: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}

/// Kept in the bot's package beside agent.json, outside the workspace, so the bot can change
/// it only through Messenger and its limits. It moves with the bot to a Hub.
private struct AgentWakeState: Codable {
    var pending: [AgentWake] = []
    var due: [AgentWake] = []
    /// When the bot's wakes fired, counted against `withoutOutsideMessages`.
    var fired: [Date] = []
}

extension WorkspaceRepository {
    public func scheduleWake(agentID: UUID, at dueAt: Date, note rawNote: String, now: Date = Date()) throws -> AgentWake {
        guard dueAt.timeIntervalSince(now) >= AgentWakeLimits.minimumDelay else {
            throw AgentWakeError("A wake must be at least \(Int(AgentWakeLimits.minimumDelay / 60)) minutes ahead. To keep working now, just continue.")
        }
        return try addWake(agentID: agentID, at: dueAt, note: rawNote, schedule: nil)
    }

    /// Schedules a wake that comes back on a cron schedule each time it fires.
    public func scheduleWake(agentID: UUID, every expression: String, note rawNote: String, now: Date = Date()) throws -> AgentWake {
        let schedule = expression.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let cron = CronSchedule(schedule) else {
            throw AgentWakeError("--wake-every needs a cron expression: minute hour day-of-month month day-of-week, such as \"0 9 * * 1-5\" for 09:00 on weekdays.")
        }
        guard let dueAt = Self.nextWakeDate(of: cron, after: now) else {
            throw AgentWakeError("That cron expression never comes round.")
        }
        return try addWake(agentID: agentID, at: dueAt, note: rawNote, schedule: schedule)
    }

    /// Recurring wakes skip times closer than the minimum delay, so none fires more often.
    private static func nextWakeDate(of cron: CronSchedule, after date: Date) -> Date? {
        cron.nextDate(after: date.addingTimeInterval(AgentWakeLimits.minimumDelay - 1), calendar: CronSchedule.localCalendar)
    }

    private func addWake(agentID: UUID, at dueAt: Date, note rawNote: String, schedule: String?) throws -> AgentWake {
        let note = rawNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty, note.count <= AgentWakeLimits.noteLength else {
            throw AgentWakeError("A wake needs a --note of at most \(AgentWakeLimits.noteLength) characters saying what to do when it fires.")
        }
        // Wakes from other bots sit outside the limits, so a bot's own wake may not pass for one.
        guard ![AgentWake.requestNote, AgentWake.answerNote].contains(note) else {
            throw AgentWakeError("That note is reserved for wakes from other bots. Say what you will do when the wake fires.")
        }
        let lastOutside = try lastOutsideMessageDate(agentID: agentID)
        return try updateWakes(agentID: agentID) { state in
            if let lastOutside { state.fired.removeAll { $0 <= lastOutside } }
            guard state.pending.filter({ !$0.isFromAnotherBot }).count < AgentWakeLimits.pending else {
                throw AgentWakeError("You already have \(AgentWakeLimits.pending) wakes scheduled. Cancel one with --cancel-wake first.")
            }
            guard state.fired.count + state.pending.filter({ !$0.isFromAnotherBot }).count < AgentWakeLimits.withoutOutsideMessages else {
                throw AgentWakeError("You have woken yourself \(AgentWakeLimits.withoutOutsideMessages) times with no message from anyone else. Wait for a message before scheduling more wakes, or ask for what you need.")
            }
            // Whole seconds, as stored, so the wake returned now equals the one listed later.
            let wake = AgentWake(dueAt: Date(timeIntervalSince1970: dueAt.timeIntervalSince1970.rounded(.up)), note: note, schedule: schedule)
            state.pending.append(wake)
            state.pending.sort { $0.dueAt < $1.dueAt }
            return wake
        }
    }

    /// A note from Noodle, due at once and shown with the bot's own wakes. It is not one of
    /// the bot's, so it counts against none of their limits.
    public func deliverWake(agentID: UUID, note: String, at now: Date = Date()) throws {
        try updateWakes(agentID: agentID) { state in
            state.due.append(AgentWake(dueAt: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.up)), note: note))
        }
    }

    /// Wakes a bot another bot asked for help or answered. One wake covers every request or answer
    /// waiting when it fires.
    func wakeFromAnotherBot(agentID: UUID, note: String, now: Date) throws {
        try updateWakes(agentID: agentID) { state in
            guard !state.pending.contains(where: { $0.isFromAnotherBot && $0.note == note }) else { return }
            state.pending.append(AgentWake(dueAt: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)),
                                           note: note))
            state.pending.sort { $0.dueAt < $1.dueAt }
        }
    }

    /// One-off wakes fired since anyone else last wrote to the bot.
    func wakesInARow(agentID: UUID) throws -> Int {
        let lastOutside = try lastOutsideMessageDate(agentID: agentID)
        return try readWakes(agentID: agentID).fired.filter { date in lastOutside.map { date > $0 } ?? true }.count
    }

    /// Hands over the wakes that fired; they are not listed again.
    public func listWakes(agentID: UUID) throws -> AgentWakeList {
        try updateWakes(agentID: agentID) { state in
            defer { state.due = [] }
            return AgentWakeList(due: state.due, pending: state.pending)
        }
    }

    public func cancelWake(agentID: UUID, id: UUID) throws -> AgentWake {
        try updateWakes(agentID: agentID) { state in
            guard let index = state.pending.firstIndex(where: { $0.id == id }) else {
                throw AgentWakeError("No scheduled wake has that ID. Use --list-wakes to see your wakes.")
            }
            return state.pending.remove(at: index)
        }
    }

    public func nextWakeDate(agentID: UUID) -> Date? {
        (try? readWakes(agentID: agentID))?.pending.first?.dueAt
    }

    /// Moves wakes that are due to the ones the bot is shown and puts recurring ones back for
    /// their next time. Returns whether any were due.
    public func takeDueWakes(agentID: UUID, at now: Date) throws -> Bool {
        try updateWakes(agentID: agentID) { state in
            let due = state.pending.filter { $0.dueAt <= now }
            guard !due.isEmpty else { return false }
            state.pending.removeAll { $0.dueAt <= now }
            state.due += due
            for wake in due {
                guard let schedule = wake.schedule, let cron = CronSchedule(schedule),
                      let next = Self.nextWakeDate(of: cron, after: now) else { continue }
                state.pending.append(AgentWake(id: wake.id, dueAt: next, note: wake.note, schedule: schedule))
            }
            state.pending.sort { $0.dueAt < $1.dueAt }
            // A recurring wake was asked for once, so only one-off wakes count as waking in a row.
            // Wakes for another bot's request or answer count too, so two bots cannot keep each other busy.
            if due.contains(where: { $0.schedule == nil }) { state.fired.append(now) }
            return true
        }
    }

    private func wakesURL(agentID: UUID) -> URL { storage(for: agentID).package.appendingPathComponent("wakes.json") }

    private func readWakes(agentID: UUID) throws -> AgentWakeState {
        let url = wakesURL(agentID: agentID)
        guard FileManager.default.fileExists(atPath: url.path) else { return AgentWakeState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AgentWakeState.self, from: Data(contentsOf: url))
    }

    /// Messenger and the runtime change the file from different threads, so changes take a lock.
    private func updateWakes<Value>(agentID: UUID, _ change: (inout AgentWakeState) throws -> Value) throws -> Value {
        let package = storage(for: agentID).package
        guard FileManager.default.fileExists(atPath: package.path) else { throw WorkspaceError.missingAgent(agentID) }
        let descriptor = Darwin.open(package.appendingPathComponent(".wakes.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(descriptor, LOCK_UN) }
        var state = try readWakes(agentID: agentID)
        let original = state
        let value = try change(&state)
        if state.pending != original.pending || state.due != original.due || state.fired != original.fired {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try AtomicFile.write(encoder.encode(state), to: wakesURL(agentID: agentID))
        }
        return value
    }

    private func lastOutsideMessageDate(agentID: UUID) throws -> Date? {
        try loadConversations().filter { $0.participantIDs.contains(agentID) }.compactMap { conversation in
            try loadMessages(conversationID: conversation.id).last { $0.author != .agent(agentID) }?.createdAt
        }.max()
    }
}
