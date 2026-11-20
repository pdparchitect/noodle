import Foundation
import NoodleCore
import NoodleMCP

/// What Pion has seen of each watched account's alerts, so an agent is woken only for what is new.
///
/// An account first watched starts from then, so its past is not news. Each check after reads back an hour from the
/// newest alert seen, as services list some alerts after their time, and leaves out the IDs it has seen already.
public struct AlertWatch: Codable, Equatable, Sendable {
    /// How far each check reads back from the newest alert seen.
    static let overlap: TimeInterval = 3_600
    /// How long what was on a board is remembered after it leaves, so one going and coming back is not news.
    static let boardMemory: TimeInterval = 7 * 86_400

    struct Account: Codable, Equatable, Sendable {
        var start: Date
        /// The alerts seen within the overlap, by ID, with their times.
        var seen: [String: Date] = [:]
    }
    private var accounts: [UUID: Account] = [:]

    public init() {}

    /// What a check found new: how many, whether the check read as many as it may so there could be more, and the
    /// times of the oldest and newest, which is the window to read them from.
    public struct News: Equatable, Sendable {
        public let count: Int
        public let capped: Bool
        public let since: Date
        public let until: Date
    }

    /// Checks `account` at `now` with `fetch`, which reads what its service raised from a time on. Returns what is new, or
    /// nil when nothing is or when the account is first watched.
    public mutating func check(_ account: UUID, at now: Date,
                               fetch: (Date) async throws -> [ServiceAlert]) async throws -> News? {
        guard let since = since(account, at: now) else { return nil }
        return take(try await fetch(since), for: account)
    }

    /// When the next check of `account` reads from, or nil when it is first watched, which starts it from `now`.
    public mutating func since(_ account: UUID, at now: Date) -> Date? {
        guard let watched = accounts[account] else {
            accounts[account] = Account(start: now)
            return nil
        }
        let newest = watched.seen.values.max() ?? watched.start
        return max(watched.start, newest.addingTimeInterval(-Self.overlap))
    }

    /// Takes in what a check of `account` found, read from `since(_:at:)`, and says what of it is new.
    public mutating func take(_ found: [ServiceAlert], for account: UUID) -> News? {
        guard var watched = accounts[account] else { return nil }
        let new = found.filter { $0.time >= watched.start && watched.seen[$0.id] == nil }
        for alert in found where alert.time >= watched.start { watched.seen[alert.id] = alert.time }
        // Older than the next check reads from, an alert cannot come back to be told apart.
        if let latest = watched.seen.values.max() {
            watched.seen = watched.seen.filter { $0.value >= latest.addingTimeInterval(-Self.overlap) }
        }
        accounts[account] = watched
        guard let first = new.map(\.time).min(), let last = new.map(\.time).max() else { return nil }
        return News(count: new.count, capped: found.count >= ServiceAlert.most, since: first, until: last)
    }

    /// Takes in the IDs on a board `account` keeps, such as a ranking, as read at `now`. Returns those newly on it, or
    /// nil when none are or when it is first watched, as what is on it then is not news.
    public mutating func board(_ account: UUID, at now: Date, found: [String]) -> [String]? {
        let first = accounts[account] == nil
        var watched = accounts[account] ?? Account(start: now)
        watched.seen = watched.seen.filter { now.timeIntervalSince($0.value) < Self.boardMemory }
        var new: [String] = []
        for id in found {
            if !first, watched.seen[id] == nil, !new.contains(id) { new.append(id) }
            watched.seen[id] = now
        }
        accounts[account] = watched
        return new.isEmpty ? nil : new
    }

    /// Forgets the accounts no longer watched, so one watched again starts afresh rather than with all it missed.
    public mutating func keep(only watched: Set<UUID>) {
        accounts = accounts.filter { watched.contains($0.key) }
    }

    /// What wakes an agent: where to look and the window, never what was found, so the agent reads the alerts itself
    /// and goes as deep as it judges.
    public static func note(_ news: News, account: String, skill: String, tool: String) -> String {
        let format = ISO8601DateFormatter()
        let since = format.string(from: Date(timeIntervalSince1970: news.since.timeIntervalSince1970.rounded(.down)))
        let until = format.string(from: Date(timeIntervalSince1970: news.until.timeIntervalSince1970.rounded(.up)))
        return #"<pion-alerts account="\#(escaped(account))" skill=".agents/skills/\#(skill)/SKILL.md" tool="\#(tool)" new="\#(news.count)\#(news.capped ? "+" : "")" since="\#(since)" until="\#(until)" />"#
    }

    /// What wakes an agent for what is newly on a board: where to look, and the IDs of what is new, which on a board
    /// are what tells it from the rest. Only IDs a trigger took are given.
    public static func note(_ entries: [String], account: String, skill: String, tool: String) -> String {
        #"<pion-alerts account="\#(escaped(account))" skill=".agents/skills/\#(skill)/SKILL.md" tool="\#(tool)" new="\#(entries.count)" entries="\#(entries.joined(separator: ","))" />"#
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    public static func load(from file: URL) -> AlertWatch {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(AlertWatch.self, from: $0) } ?? AlertWatch()
    }

    public func save(to file: URL) throws {
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
    }
}

/// What Pion watches on an MCP server it does not answer for itself: a board one of the server's tools reads, such as
/// a ranking, called as an agent would call it, every `interval`, waking the agents for what is newly on it.
public struct MCPTrigger: Sendable {
    /// The server's tool that reads the board, and the arguments it is called with, as JSON.
    public let tool: String
    public let arguments: Data
    public let interval: TimeInterval
    /// What the skill of a connection it watches says about its wake: what the note's parts mean and how to read
    /// what it names.
    public let skill: String
    /// The IDs on the board, from the tool's answer, each one `isEntryID` allows.
    public let entries: @Sendable (Data) throws -> [String]

    public init(tool: String, arguments: [String: Any], interval: TimeInterval, skill: String,
                entries: @escaping @Sendable (Data) throws -> [String]) {
        self.tool = tool
        // Fixed arguments written in code, so they always make JSON.
        self.arguments = try! JSONSerialization.data(withJSONObject: arguments, options: .sortedKeys)
        self.interval = interval; self.skill = skill; self.entries = entries
    }

    /// Whether a board's entry ID may go in the note that wakes an agent: a short run of letters, digits and the
    /// marks IDs such as CVE-2026-1234 or GHSA-xxxx-xxxx-xxxx use, and nothing else the server could send.
    public static func isEntryID(_ id: String) -> Bool {
        (1...64).contains(id.count) && id.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._:").contains($0)
        }
    }
}

/// Checks the watched accounts' services every few minutes, with each account's own sign-in, and says which agents to
/// wake; an MCP server's board, every hour or as its trigger says. What it has seen is kept in a file, so a relaunch
/// neither repeats alerts nor misses those raised meanwhile.
@MainActor public final class AlertWatcher {
    /// How often each watched account is checked.
    public static let interval: Duration = .seconds(300)

    /// What one check of an account found.
    public enum Checked: Equatable, Sendable {
        case nothingNew
        /// Something new, in a few words; its agents were woken for it.
        case found(String)
        /// The check failed, saying why.
        case failed(String)
    }

    private var watch: AlertWatch
    private let file: URL
    /// Reaches an account's service with its own sign-in.
    private let access: @Sendable (ToolConnection) async throws -> any ServiceAccess
    /// Makes a request of a connection's MCP server, as an agent's goes.
    private let call: @Sendable (ToolConnection, MCPBridgeRequest) async throws -> Data
    /// When each MCP server's board was last read, so it is read only as often as its trigger says.
    private var boardsRead: [UUID: Date] = [:]
    private var checking = false

    public convenience init(file: URL, service: ToolConnectionService) {
        self.init(file: file, access: { try await service.access(for: $0) },
                  call: { try await service.perform($1, connection: $0) })
    }

    init(file: URL, access: @escaping @Sendable (ToolConnection) async throws -> any ServiceAccess,
         call: @escaping @Sendable (ToolConnection, MCPBridgeRequest) async throws -> Data = { _, _ in
             throw ToolConnectionError.message("No MCP server can be reached here.")
         }) {
        self.file = file
        self.access = access
        self.call = call
        watch = AlertWatch.load(from: file)
    }

    /// The trigger Pion watches a connection's MCP server with, by the catalogue entry it was made from.
    nonisolated static func trigger(for connection: ToolConnection) -> MCPTrigger? {
        guard connection.adapter == nil else { return nil }
        return connection.catalogueID.flatMap { PionCatalogue.triggers[$0] }
    }

    /// What the skill of this connection says about its wake, for one Pion watches: what the note's parts mean and
    /// which tool reads what it names, and nothing of what to do about it.
    public nonisolated static func skillText(for connection: ToolConnection) -> String? {
        trigger(for: connection)?.skill ?? skillText(for: connection.adapter)
    }

    /// What the skill of a connection served by the adapter of this name says about its alerts wake, for one Pion
    /// watches: what the note's parts mean and which tool reads the alerts, and nothing of what to do with them.
    public nonisolated static func skillText(for adapter: String?) -> String? {
        guard let tool = adapter.flatMap({ PionAdapters.all[$0] as? OperationAdapter })?.watchedTool else { return nil }
        return """
        ## Alerts

        Pion checks this account for new serious alerts every five minutes and wakes the agents it is assigned to with a \
        note such as `<pion-alerts account="…" skill="…" tool="\(tool)" new="3" since="…" until="…" />`. The note says \
        where to look and when, not what was found: `new` is how many, with a `+` when there may be more, and `since` and \
        `until` are the times of the oldest and the newest. Read them with `\(tool)`.
        """
    }

    /// Whether Pion watches this connection: its adapter has a feed to watch, or its MCP server a board.
    public nonisolated static func watches(_ connection: ToolConnection) -> Bool {
        trigger(for: connection) != nil || watches(connection.adapter)
    }

    /// Whether Pion can watch connections served by the adapter of this name.
    public nonisolated static func watches(_ adapter: String?) -> Bool {
        adapter.flatMap { PionAdapters.all[$0] as? OperationAdapter }?.watchedTool != nil
    }

    /// Checks each account, signed in and assigned to `agents`, once, and wakes those agents with a note for any that has
    /// something new. A check that fails is tried again next time, from where the last one left off. What was seen of
    /// the accounts in `keeping` stays, such as one waiting to be signed in again, so it picks up where it stopped;
    /// any other is forgotten. Says what each account checked found, or why it could not be checked; one not due yet,
    /// or first watched from now, is left out.
    @discardableResult
    public func check(_ accounts: [(connection: ToolConnection, agents: [UUID])], keeping: Set<UUID>, at now: Date = Date(),
                      wake: (UUID, String) -> Void) async -> [UUID: Checked] {
        guard !checking else { return [:] }
        checking = true
        defer { checking = false }
        var watch = watch, checked: [UUID: Checked] = [:]
        let watched = keeping.union(accounts.map(\.connection.id))
        watch.keep(only: watched)
        boardsRead = boardsRead.filter { watched.contains($0.key) }
        for (connection, agents) in accounts where !agents.isEmpty {
            do {
                if let trigger = Self.trigger(for: connection) {
                    if let read = boardsRead[connection.id], now.timeIntervalSince(read) < trigger.interval { continue }
                    let request = MCPBridgeRequest(session: "", connectionID: connection.id, action: .call, tool: trigger.tool,
                                                   arguments: trigger.arguments)
                    let found = try trigger.entries(try await call(connection, request))
                    let new = watch.board(connection.id, at: now, found: found)
                    boardsRead[connection.id] = now
                    guard let new else { checked[connection.id] = .nothingNew; continue }
                    checked[connection.id] = .found("\(new.count) new: " + new.joined(separator: ", "))
                    let note = AlertWatch.note(new, account: connection.name, skill: connection.skillName, tool: trigger.tool)
                    for agent in agents { wake(agent, note) }
                    continue
                }
                guard let name = connection.adapter, let adapter = PionAdapters.all[name] as? OperationAdapter,
                      let tool = adapter.watchedTool else { continue }
                guard let since = watch.since(connection.id, at: now) else { continue }
                let found = try await adapter.alerts(since: since, connection: connection, access: try await access(connection))
                guard let news = watch.take(found, for: connection.id) else { checked[connection.id] = .nothingNew; continue }
                checked[connection.id] = .found("\(news.count)\(news.capped ? "+" : "") new alert\(news.count == 1 && !news.capped ? "" : "s")")
                let note = AlertWatch.note(news, account: connection.name, skill: connection.skillName, tool: tool)
                for agent in agents { wake(agent, note) }
            } catch {
                checked[connection.id] = .failed(error.localizedDescription)
            }
        }
        self.watch = watch
        try? watch.save(to: file)
        return checked
    }
}
