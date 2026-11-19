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
        let escaped = account.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return #"<pion-alerts account="\#(escaped)" skill=".agents/skills/\#(skill)/SKILL.md" tool="\#(tool)" new="\#(news.count)\#(news.capped ? "+" : "")" since="\#(since)" until="\#(until)" />"#
    }

    public static func load(from file: URL) -> AlertWatch {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(AlertWatch.self, from: $0) } ?? AlertWatch()
    }

    public func save(to file: URL) throws {
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
    }
}

/// Checks the watched accounts' services every few minutes, with each account's own sign-in, and says which agents to
/// wake. What it has seen is kept in a file, so a relaunch neither repeats alerts nor misses those raised meanwhile.
@MainActor public final class AlertWatcher {
    /// How often each watched account is checked.
    public static let interval: Duration = .seconds(300)

    private var watch: AlertWatch
    private let file: URL
    /// Reaches an account's service with its own sign-in.
    private let access: @Sendable (ToolConnection) async throws -> any ServiceAccess
    private var checking = false

    public convenience init(file: URL, service: ToolConnectionService) {
        self.init(file: file) { try await service.access(for: $0) }
    }

    init(file: URL, access: @escaping @Sendable (ToolConnection) async throws -> any ServiceAccess) {
        self.file = file
        self.access = access
        watch = AlertWatch.load(from: file)
    }

    /// Whether Pion can watch connections served by the adapter of this name.
    public static func watches(_ adapter: String?) -> Bool {
        adapter.flatMap { PionAdapters.all[$0] as? OperationAdapter }?.watchedTool != nil
    }

    /// Checks each account, signed in and assigned to `agents`, once, and wakes those agents with a note for any that has
    /// something new. A check that fails is tried again next time, from where the last one left off. What was seen of
    /// the accounts in `keeping` stays, such as one waiting to be signed in again, so it picks up where it stopped;
    /// any other is forgotten. Says why each account that could not be checked could not.
    @discardableResult
    public func check(_ accounts: [(connection: ToolConnection, agents: [UUID])], keeping: Set<UUID>, at now: Date = Date(),
                      wake: (UUID, String) -> Void) async -> [UUID: String] {
        guard !checking else { return [:] }
        checking = true
        defer { checking = false }
        var watch = watch, problems: [UUID: String] = [:]
        watch.keep(only: keeping.union(accounts.map(\.connection.id)))
        for (connection, agents) in accounts {
            guard !agents.isEmpty, let name = connection.adapter, let adapter = PionAdapters.all[name] as? OperationAdapter,
                  let tool = adapter.watchedTool else { continue }
            guard let since = watch.since(connection.id, at: now) else { continue }
            do {
                let found = try await adapter.alerts(since: since, connection: connection, access: try await access(connection))
                guard let news = watch.take(found, for: connection.id) else { continue }
                let note = AlertWatch.note(news, account: connection.name, skill: connection.skillName, tool: tool)
                for agent in agents { wake(agent, note) }
            } catch {
                problems[connection.id] = error.localizedDescription
            }
        }
        self.watch = watch
        try? watch.save(to: file)
        return problems
    }
}
