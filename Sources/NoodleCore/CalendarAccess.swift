import Foundation

/// One calendar on this Mac, as Noodle shows it in Settings and grants it to bots.
public struct CalendarRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var title: String
    public var source: String
    public var writable: Bool
    public var colour: Int?
    public init(id: String, title: String, source: String, writable: Bool, colour: Int? = nil) {
        self.id = id; self.title = title; self.source = source; self.writable = writable; self.colour = colour
    }
}

/// Which calendars each bot may use. Stored beside the browser and computer assignments.
public struct CalendarAssignments: Codable, Sendable {
    public var version = 1
    public var calendars: [CalendarRecord] = []
    public var agents: [String: Set<String>] = [:]
    public init() {}
    public func assigned(to agent: UUID) -> Set<String> { agents[agent.uuidString] ?? [] }
    public func permits(_ calendar: String?, agent: UUID) -> Bool { calendar.map { assigned(to: agent).contains($0) } ?? false }
    public static func load(root: URL) throws -> Self {
        let url = root.appendingPathComponent("calendars.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let value = try JSONDecoder().decode(Self.self, from: MCPBridgeFiles.read(url, limit: 8 * 1_048_576))
        guard value.version == 1 else { throw ToolProviderError("Unsupported calendar assignments. Existing settings were not changed.") }
        return value
    }
    public func save(root: URL) throws { try MCPBridgeFiles.write(self, to: root.appendingPathComponent("calendars.json")) }
    /// What the tool broker enforces. A registry that could not be read grants nothing.
    public func toolAssignments(readable: Bool) -> [UUID: Set<String>] {
        guard readable else { return [:] }
        return Dictionary(uniqueKeysWithValues: agents.compactMap { key, ids in UUID(uuidString: key).map { ($0, ids) } })
    }
}
