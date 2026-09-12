import Foundation

/// Selects a connection from the skill-local invocation path, not the shared
/// executable's resolved location. This is routing only; the broker authorizes it.
public struct MCPInvocationContext: Equatable, Sendable {
    public let workspace: URL
    public let skillName: String?

    public static func resolve(invocationPath: String, currentDirectory: URL) throws -> Self {
        let cwd = currentDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard let layout = try? AgentStorageLayout.containing(cwd) else {
            throw MCPConnectionError.message("Run mcpshim from this bot's workspace or its skill directory.")
        }
        let workspace = layout.workspace
        let invoked = URL(fileURLWithPath: invocationPath, relativeTo: cwd).standardizedFileURL
        // Resolve parent aliases (.claude/skills/...) but NOT the mcpshim symlink.
        let parent = invoked.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let skills = workspace.appendingPathComponent(".agents/skills").standardizedFileURL
        let name = parent.lastPathComponent
        let local = invoked.lastPathComponent == "mcpshim" && parent.deletingLastPathComponent() == skills &&
            name.hasPrefix("mcp-") && name.count > 4 && name.utf8.count <= 64 &&
            name.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0) }
        return Self(workspace: workspace, skillName: local ? name : nil)
    }
}
