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

// TODO(0.22.0): Remove ComputerAgentSkill, its call in synchronizeAgentWorkspace and its tests after verifying
// upgrades pass through the published 0.21.0 milestone, which runs this the first time it syncs a bot's workspace.
public enum ComputerAgentSkill {
    /// Bots now reach computers through `messenger tool computer`. Remove what earlier versions
    /// wrote: the hand-written skill with its command link, and the request mailbox.
    public static func removeLegacy(workspace: URL) {
        if let folder = try? WorkspaceMailbox(workspace: workspace, path: ".agents/skills/computer") {
            if folder.contains(ToolProviderSkills.marker) { folder.remove("computer") }
            else { try? WorkspaceMailbox.synchronizeSkill(workspace: workspace, name: "computer", enabled: false, instructions: "", command: "computer", executable: nil) }
        }
        if let bridge = try? WorkspaceMailbox(workspace: workspace, path: ".noodle/computer-bridge"), let names = try? bridge.names() {
            names.forEach(bridge.remove)
            (try? WorkspaceMailbox(workspace: workspace, path: ".noodle"))?.removeEmptyDirectory("computer-bridge")
        }
    }
}
