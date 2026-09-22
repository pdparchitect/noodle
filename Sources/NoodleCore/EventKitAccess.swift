import Foundation

/// One calendar or reminder list on this Mac, as Noodle shows it in Settings and grants
/// it to bots. EventKit models both as the same thing, and so does Noodle.
public struct EventKitList: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var title: String
    public var source: String
    public var writable: Bool
    public var colour: Int?
    public init(id: String, title: String, source: String, writable: Bool, colour: Int? = nil) {
        self.id = id; self.title = title; self.source = source; self.writable = writable; self.colour = colour
    }
}

/// Which calendars or reminder lists each bot may use. One shape, one file per kind,
/// stored beside the browser and computer assignments.
public struct EventKitAssignments: Codable, Sendable {
    /// Also the resource kind the tool broker enforces, so the two can never drift apart.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case calendar, reminderList = "reminder-list"
        public var file: String { self == .calendar ? "calendars.json" : "reminders.json" }
        /// What a person is told they are giving away.
        public var noun: String { self == .calendar ? "calendar" : "reminder list" }
    }
    public var version = 1
    public var lists: [EventKitList] = []
    public var agents: [String: Set<String>] = [:]
    public init() {}
    public func assigned(to agent: UUID) -> Set<String> { agents[agent.uuidString] ?? [] }
    public func permits(_ list: String?, agent: UUID) -> Bool { list.map { assigned(to: agent).contains($0) } ?? false }
    public static func load(root: URL, kind: Kind) throws -> Self {
        let url = root.appendingPathComponent(kind.file)
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let value = try JSONDecoder().decode(Self.self, from: MCPBridgeFiles.read(url, limit: 8 * 1_048_576))
        guard value.version == 1 else {
            throw ToolProviderError("Unsupported \(kind.noun) assignments. Existing settings were not changed.")
        }
        return value
    }
    public func save(root: URL, kind: Kind) throws { try MCPBridgeFiles.write(self, to: root.appendingPathComponent(kind.file)) }
    /// What the tool broker enforces. A registry that could not be read grants nothing.
    public func toolAssignments(readable: Bool) -> [UUID: Set<String>] {
        guard readable else { return [:] }
        return Dictionary(uniqueKeysWithValues: agents.compactMap { key, ids in UUID(uuidString: key).map { ($0, ids) } })
    }
}
