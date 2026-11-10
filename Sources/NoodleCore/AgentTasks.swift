import Darwin
import Foundation

/// A piece of work a bot keeps through Messenger, so its person can see what it is doing and
/// what it waits on. Only the bot that owns a task changes it; anyone else answers in its thread.
public struct AgentTask: Codable, Hashable, Identifiable, Sendable {
    public enum State: String, Codable, CaseIterable, Sendable {
        case open, waiting, done, dropped

        public var isFinished: Bool { self == .done || self == .dropped }
    }

    public let id: UUID
    public var title: String
    public var state: State
    /// The thread the work came from; nil for work of the bot's own, such as a standing assignment.
    public let conversationID: UUID?
    /// Who a waiting task waits on: the person, or another bot in its thread. Nil while waiting
    /// on something outside Noodle, and whenever the task is not waiting.
    public var waitingOn: MessageAuthor?
    public var note: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String, state: State = .open, conversationID: UUID? = nil,
                waitingOn: MessageAuthor? = nil, note: String? = nil, createdAt: Date, updatedAt: Date? = nil) {
        self.id = id; self.title = title; self.state = state; self.conversationID = conversationID
        self.waitingOn = waitingOn; self.note = note; self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
    }
}

/// Which task a person's message is about, so the bot that owns it knows what to move on.
public struct TaskReference: Codable, Hashable, Sendable {
    public let id: UUID
    public let agentID: UUID
    public let title: String

    public init(id: UUID, agentID: UUID, title: String) { self.id = id; self.agentID = agentID; self.title = title }
    public init(_ task: AgentTask, agentID: UUID) { self.init(id: task.id, agentID: agentID, title: task.title) }
}

/// What `--list-tasks` returns: the bot's own tasks, and other bots' tasks waiting on it.
public struct AgentTaskList: Codable, Hashable, Sendable {
    public struct Waiting: Codable, Hashable, Sendable {
        public let ownerID: UUID
        public let ownerName: String
        public let task: AgentTask
    }

    public let mine: [AgentTask]
    public let waitingOnMe: [Waiting]
}

public enum AgentTaskLimits {
    /// Open and waiting tasks one bot can have, so a runaway bot cannot flood the list.
    public static let open = 50
    public static let titleLength = 120
    public static let noteLength = 300
    /// How long a done or dropped task stays visible.
    public static let finishedKept: TimeInterval = 7 * 86_400
}

struct AgentTaskError: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}

extension WorkspaceRepository {
    public func addTask(agentID: UUID, title rawTitle: String, conversationID: UUID? = nil,
                        note rawNote: String? = nil, now: Date = Date()) throws -> AgentTask {
        let title = try Self.taskTitle(rawTitle)
        let note = try Self.taskNote(rawNote)
        // Also checks the bot is in the thread.
        if let conversationID { _ = try participantRoster(for: agentID, conversationID: conversationID) }
        return try updateTasks(agentID: agentID, now: now) { tasks in
            guard tasks.filter({ !$0.state.isFinished }).count < AgentTaskLimits.open else {
                throw AgentTaskError("You already have \(AgentTaskLimits.open) open tasks. Mark finished ones done or dropped with --update-task first.")
            }
            let task = AgentTask(title: title, conversationID: conversationID, note: note, createdAt: Self.wholeSeconds(now))
            tasks.append(task)
            return task
        }
    }

    /// Giving a state or `waitingOn` sets who the task waits on afresh: `waitingOn` goes only with
    /// `.waiting`, and leaving waiting forgets it. A nil `note` keeps the note, an empty one removes it.
    public func updateTask(agentID: UUID, id: UUID, state: AgentTask.State? = nil, waitingOn: MessageAuthor? = nil,
                           title rawTitle: String? = nil, note rawNote: String? = nil, now: Date = Date()) throws -> AgentTask {
        let title = try rawTitle.map(Self.taskTitle)
        let note = try rawNote.map { try Self.taskNote($0) ?? "" }
        let current = try loadTasks(agentID: agentID).first { $0.id == id }
        guard let current else { throw AgentTaskError("You have no task with that ID. Use --list-tasks to see your tasks.") }
        let newState = state ?? current.state
        if waitingOn != nil {
            guard newState == .waiting else { throw AgentTaskError("--on names who a waiting task waits on; use it with --state waiting.") }
            try checkWaitingOn(waitingOn, agentID: agentID, conversationID: current.conversationID)
        }
        return try updateTasks(agentID: agentID, now: now) { tasks in
            guard let index = tasks.firstIndex(where: { $0.id == id }) else {
                throw AgentTaskError("You have no task with that ID. Use --list-tasks to see your tasks.")
            }
            var task = tasks[index]
            if let title { task.title = title }
            if let note { task.note = note.isEmpty ? nil : note }
            if state != nil || waitingOn != nil { task.waitingOn = newState == .waiting ? waitingOn : nil }
            task.state = newState
            task.updatedAt = Self.wholeSeconds(now)
            tasks[index] = task
            return task
        }
    }

    public func listTasks(agentID: UUID, now: Date = Date()) throws -> AgentTaskList {
        let mine = try currentTasks(agentID: agentID, now: now)
        let waiting = try loadAgents().filter { $0.id != agentID }.flatMap { owner in
            ((try? loadTasks(agentID: owner.id)) ?? [])
                .filter { $0.state == .waiting && $0.waitingOn == .agent(agentID) }
                .map { AgentTaskList.Waiting(ownerID: owner.id, ownerName: owner.displayName, task: $0) }
        }
        return AgentTaskList(mine: mine, waitingOnMe: waiting)
    }

    /// The bot's tasks, oldest first, once finished ones past their week are cleared.
    public func currentTasks(agentID: UUID, now: Date = Date()) throws -> [AgentTask] {
        try updateTasks(agentID: agentID, now: now) { $0 }
    }

    /// Puts a copy of a bot's tasks in place, as a Hub lists them for a bot it runs. Returns whether they changed.
    @discardableResult
    public func replaceTasks(agentID: UUID, with tasks: [AgentTask], now: Date = Date()) throws -> Bool {
        try updateTasks(agentID: agentID, now: now) { current in
            defer { current = tasks }
            return current != tasks
        }
    }

    /// The bot's tasks as stored, oldest first, without clearing anything.
    public func loadTasks(agentID: UUID) throws -> [AgentTask] {
        let url = tasksURL(agentID: agentID)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([AgentTask].self, from: Data(contentsOf: url))
    }

    private func checkWaitingOn(_ author: MessageAuthor?, agentID: UUID, conversationID: UUID?) throws {
        guard case .agent(let other) = author else { return }
        guard other != agentID else { throw AgentTaskError("A task cannot wait on yourself.") }
        if let conversationID {
            guard try loadConversations().first(where: { $0.id == conversationID })?.participantIDs.contains(other) == true else {
                throw AgentTaskError("That bot is not in this task's conversation. Use --list-participants to see who is.")
            }
        } else {
            guard try loadAgents().contains(where: { $0.id == other }) else { throw WorkspaceError.missingAgent(other) }
        }
    }

    private static func taskTitle(_ raw: String) throws -> String {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= AgentTaskLimits.titleLength, !title.contains(where: \.isNewline) else {
            throw AgentTaskError("A task title is one line of at most \(AgentTaskLimits.titleLength) characters.")
        }
        return title
    }

    private static func taskNote(_ raw: String?) throws -> String? {
        guard let note = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else { return nil }
        guard note.count <= AgentTaskLimits.noteLength else {
            throw AgentTaskError("A task note is at most \(AgentTaskLimits.noteLength) characters.")
        }
        return note
    }

    /// As stored, so a task returned now equals the one listed later.
    private static func wholeSeconds(_ date: Date) -> Date { Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)) }

    private func tasksURL(agentID: UUID) -> URL { storage(for: agentID).package.appendingPathComponent("tasks.json") }

    /// Messenger and the app change the file from different threads, so changes take a lock. Every
    /// change also clears finished tasks past their week and tasks whose thread is gone.
    private func updateTasks<Value>(agentID: UUID, now: Date, _ change: (inout [AgentTask]) throws -> Value) throws -> Value {
        let package = storage(for: agentID).package
        guard FileManager.default.fileExists(atPath: package.path) else { throw WorkspaceError.missingAgent(agentID) }
        let threads = Set(try loadConversations().map(\.id))
        let descriptor = Darwin.open(package.appendingPathComponent(".tasks.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(descriptor, LOCK_UN) }
        let original = try loadTasks(agentID: agentID)
        var tasks = original.filter { task in
            (task.conversationID.map(threads.contains) ?? true)
                && !(task.state.isFinished && now.timeIntervalSince(task.updatedAt) > AgentTaskLimits.finishedKept)
        }
        let value = try change(&tasks)
        if tasks != original {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try AtomicFile.write(encoder.encode(tasks), to: tasksURL(agentID: agentID))
        }
        return value
    }
}
