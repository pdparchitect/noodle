import Foundation

/// One user-authorized account, not one unique endpoint. URLs are never keys.
public struct MCPConnectionRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let endpoint: URL
    public var description: String
    public var instructions: String
    public fileprivate(set) var skillName: String
    public var iconData: Data?

    public init(id: UUID = UUID(), name: String, endpoint: URL,
                description: String = "", instructions: String = "") throws {
        self.id = id
        self.name = try ConversationName.validated(name)
        self.endpoint = try Self.validatedEndpoint(endpoint)
        self.description = String(description.prefix(1_000))
        self.instructions = String(instructions.prefix(20_000))
        let slug = name.lowercased().unicodeScalars.map {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").contains($0) ? String($0) : "-"
        }.joined().split(separator: "-").joined(separator: "-")
        let prefix = String(slug.prefix(20)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        self.skillName = "mcp-" + (prefix.isEmpty ? "connection" : prefix)
    }

    public static func validatedEndpoint(_ url: URL) throws -> URL {
        guard url.scheme?.lowercased() == "https", url.fragment == nil,
              let result = MessageLink.publicWebURL(from: url) else {
            throw MCPConnectionError.message("Enter a public HTTPS server URL without credentials or a fragment.")
        }
        return result
    }
}

public enum MCPConnectionError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

public struct MCPRegistry: Codable, Equatable, Sendable {
    public var connections: [MCPConnectionRecord] = []
    public var assignments: [String: [UUID]] = [:]
    public init() {}
    public func assigned(to agentID: UUID) -> [MCPConnectionRecord] {
        let ids = Set(assignments[agentID.uuidString.lowercased()] ?? [])
        return connections.filter { ids.contains($0.id) }
    }
    public mutating func assign(_ ids: Set<UUID>, to agentID: UUID) throws {
        guard ids.isSubset(of: Set(connections.map(\.id))) else {
            throw MCPConnectionError.message("One of the selected tool connections no longer exists.")
        }
        assignments[agentID.uuidString.lowercased()] = ids.sorted { $0.uuidString < $1.uuidString }
    }
    public mutating func remove(_ id: UUID) {
        connections.removeAll { $0.id == id }
        for key in assignments.keys { assignments[key]?.removeAll { $0 == id } }
    }
    public static func load(root: URL) throws -> Self {
        let file = root.appendingPathComponent("MCP/connections.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return Self() }
        var registry = try JSONDecoder().decode(Self.self, from: MCPBridgeFiles.read(file, limit: 32 * 1_048_576))
        try registry.validate()
        registry.normalizeSkillNames()
        return registry
    }
    public mutating func save(root: URL) throws {
        try validate()
        var next = self
        next.normalizeSkillNames()
        let folder = root.appendingPathComponent("MCP", isDirectory: true)
        guard (try? FileManager.default.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType) != .typeSymbolicLink else {
            throw MCPConnectionError.message("The MCP registry directory must not be a symbolic link.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(next).write(to: folder.appendingPathComponent("connections.json"), options: .atomic)
        self = next
    }

    // Allocate once when saving; preserve clean names across display-name edits,
    // removals and reloads. Legacy UUID-suffixed folders migrate on workspace sync.
    private mutating func normalizeSkillNames() {
        func base(_ connection: MCPConnectionRecord) -> String {
            let suffix = "-" + connection.id.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            return connection.skillName.hasSuffix(suffix) ? String(connection.skillName.dropLast(suffix.count)) : connection.skillName
        }
        let reserved = Set(connections.filter { base($0) == $0.skillName }.map(\.skillName))
        var used: Set<String> = []
        for index in connections.indices {
            let original = connections[index].skillName
            let stem = base(connections[index])
            var candidate = stem
            var number = 2
            while used.contains(candidate) || (original != candidate && reserved.contains(candidate)) {
                candidate = String(stem.prefix(52)) + "-\(number)"
                number += 1
            }
            connections[index].skillName = candidate
            used.insert(candidate)
        }
    }
    private func validate() throws {
        guard Set(connections.map(\.id)).count == connections.count else {
            throw MCPConnectionError.message("Duplicate MCP connection identifiers.")
        }
        for connection in connections {
            _ = try ConversationName.validated(connection.name)
            _ = try MCPConnectionRecord.validatedEndpoint(connection.endpoint)
            guard connection.skillName.hasPrefix("mcp-"), connection.skillName.count > 4,
                  connection.skillName.utf8.count <= 64,
                  connection.skillName.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0) }),
                  connection.description.count <= 1_000, connection.instructions.count <= 20_000,
                  (connection.iconData?.count ?? 0) <= 131_072 else {
                throw MCPConnectionError.message("Invalid saved MCP connection.")
            }
        }
    }
}

// TODO(0.22.0): Remove MCPSkillWriter, its call in synchronizeAgentWorkspace and its tests after verifying
// upgrades pass through the published 0.21.0 milestone, which runs this the first time it syncs a bot's workspace.
public enum MCPSkillWriter {
    /// Bots now reach tool connections through `messenger tool`. Remove what earlier versions
    /// wrote: one hand-written skill per connection with its mcpshim link, the list that
    /// tracked them, and the request mailbox. A generated skill of the same name stays.
    public static func removeLegacy(workspace: URL) {
        if let agents = try? WorkspaceMailbox(workspace: workspace, path: ".agents"),
           let names = try? JSONDecoder().decode([String].self, from: agents.read("mcp-skills.json", limit: 1_048_576)) {
            let skills = try? WorkspaceMailbox(workspace: workspace, path: ".agents/skills")
            for name in names where isManagedName(name) {
                guard let folder = try? WorkspaceMailbox(workspace: workspace, path: ".agents/skills/" + name) else { continue }
                folder.remove("mcpshim")
                if !folder.contains(ToolProviderSkills.marker) {
                    folder.remove("SKILL.md")
                    skills?.removeEmptyDirectory(name)
                    if let native = try? WorkspaceMailbox(workspace: workspace, path: ".claude/skills"),
                       native.linkDestination(name) == "../../.agents/skills/" + name { native.remove(name) }
                }
            }
            agents.remove("mcp-skills.json")
        }
        if let bridge = try? WorkspaceMailbox(workspace: workspace, path: ".noodle/mcp-bridge"), let names = try? bridge.names() {
            names.forEach(bridge.remove)
            (try? WorkspaceMailbox(workspace: workspace, path: ".noodle"))?.removeEmptyDirectory("mcp-bridge")
        }
    }
    private static func isManagedName(_ value: String) -> Bool {
        value.hasPrefix("mcp-") && value.count <= 64 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}
