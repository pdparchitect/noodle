import Foundation
import MailBridge

/// Which bots may use which Noodle Mail mailboxes, with the mailbox list last read from Noodle Mail.
public struct MailAssignments: Codable, Sendable {
    public var version = 1
    public var mailboxes: [RemoteMailbox] = []
    public var agents: [String: Set<UUID>] = [:]
    public init() {}
    public func assigned(to agent: UUID) -> Set<UUID> { agents[agent.uuidString] ?? [] }
    public static func load(root: URL) throws -> Self {
        let url = root.appendingPathComponent("mail.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let value = try JSONDecoder().decode(Self.self, from: MCPBridgeFiles.read(url, limit: 8 * 1_048_576))
        guard value.version == 1 else { throw MailError("Unsupported mailbox assignments. Existing settings were not changed.") }
        return value
    }
    public func save(root: URL) throws { try MCPBridgeFiles.write(self, to: root.appendingPathComponent("mail.json")) }
    /// What the tool broker enforces. A file that could not be read grants nothing.
    public func toolAssignments(readable: Bool) -> [UUID: Set<String>] {
        guard readable else { return [:] }
        return Dictionary(uniqueKeysWithValues: agents.compactMap { key, ids in UUID(uuidString: key).map { ($0, Set(ids.map(\.uuidString))) } })
    }
}
