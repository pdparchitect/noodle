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
// TODO(0.22.0): Remove BrowserAgentSkill, its call in synchronizeAgentWorkspace and its tests after verifying
// upgrades pass through the published 0.21.0 milestone, which runs this the first time it syncs a bot's workspace.
public enum BrowserAgentSkill {
    /// Bots now reach browsers through `messenger tool browser`. Remove what earlier versions
    /// wrote: the hand-written skill with its command link, and the request mailbox.
    public static func removeLegacy(workspace: URL) {
        if let folder = try? WorkspaceMailbox(workspace: workspace, path: ".agents/skills/browser") {
            if folder.contains(ToolProviderSkills.marker) { folder.remove("browser") }
            else { try? WorkspaceMailbox.synchronizeSkill(workspace: workspace, name: "browser", enabled: false, instructions: "", command: "browser", executable: nil) }
        }
        if let bridge = try? WorkspaceMailbox(workspace: workspace, path: ".noodle/browser-bridge"), let names = try? bridge.names() {
            names.forEach(bridge.remove)
            (try? WorkspaceMailbox(workspace: workspace, path: ".noodle"))?.removeEmptyDirectory("browser-bridge")
        }
    }
}
