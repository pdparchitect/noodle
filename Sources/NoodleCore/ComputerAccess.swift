import ComputerBridge
import Foundation

public struct ComputerAssignments: Codable, Sendable {
    public var version = 1
    public var computers: [RemoteComputer] = []
    public var agents: [String: Set<UUID>] = [:]
    public init() {}
    public func assigned(to agent: UUID) -> Set<UUID> { agents[agent.uuidString] ?? [] }
    public func permits(_ computer: UUID?, agent: UUID) -> Bool {
        computer.map { assigned(to: agent).contains($0) } ?? false
    }
    public static func load(root: URL) throws -> Self {
        let url = root.appendingPathComponent("computers.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let result = try JSONDecoder().decode(Self.self, from: MCPBridgeFiles.read(url, limit: 8 * 1_048_576))
        guard result.version == 1 else { throw ComputerBridgeError("Unsupported computer assignments. They were not changed.") }
        return result
    }
    public func save(root: URL) throws {
        try MCPBridgeFiles.write(self, to: root.appendingPathComponent("computers.json"))
    }
    /// What the tool broker enforces. A registry that could not be read grants nothing.
    public func toolAssignments(readable: Bool) -> [UUID: Set<String>] {
        guard readable else { return [:] }
        return Dictionary(uniqueKeysWithValues: agents.compactMap { key, ids in UUID(uuidString: key).map { ($0, Set(ids.map(\.uuidString))) } })
    }
}

