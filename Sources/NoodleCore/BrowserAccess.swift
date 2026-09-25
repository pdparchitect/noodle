import BrowserBridge
import Foundation

public struct BrowserAssignments: Codable, Sendable {
    public var version = 1
    public var browsers: [RemoteBrowser] = []
    public var agents: [String: Set<UUID>] = [:]
    public init() {}
    public func assigned(to agent: UUID) -> Set<UUID> { agents[agent.uuidString] ?? [] }
    public func permits(_ browser: UUID?, agent: UUID) -> Bool { browser.map { assigned(to: agent).contains($0) } ?? false }
    public static func load(root: URL) throws -> Self {
        let url = root.appendingPathComponent("browsers.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let value = try JSONDecoder().decode(Self.self, from: MCPBridgeFiles.read(url, limit: 8 * 1_048_576))
        guard value.version == 1 else { throw BrowserError("Unsupported browser assignments. Existing settings were not changed.") }
        return value
    }
    public func save(root: URL) throws { try MCPBridgeFiles.write(self, to: root.appendingPathComponent("browsers.json")) }
    /// What the tool broker enforces. A registry that could not be read grants nothing.
    public func toolAssignments(readable: Bool) -> [UUID: Set<String>] {
        guard readable else { return [:] }
        return Dictionary(uniqueKeysWithValues: agents.compactMap { key, ids in UUID(uuidString: key).map { ($0, Set(ids.map(\.uuidString))) } })
    }
}
