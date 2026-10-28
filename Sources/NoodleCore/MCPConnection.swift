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
    /// Programs Noodle starts. An older build does not read this key, so it never treats one as a public server.
    public var programs: [MCPProgramRecord] = []
    public var assignments: [String: [UUID]] = [:]
    public init() {}
    private enum CodingKeys: String, CodingKey { case connections, assignments, programs }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        connections = try container.decodeIfPresent([MCPConnectionRecord].self, forKey: .connections) ?? []
        assignments = try container.decodeIfPresent([String: [UUID]].self, forKey: .assignments) ?? [:]
        programs = try container.decodeIfPresent([MCPProgramRecord].self, forKey: .programs) ?? []
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(connections, forKey: .connections)
        try container.encode(assignments, forKey: .assignments)
        if !programs.isEmpty { try container.encode(programs, forKey: .programs) }
    }
    public func assigned(to agentID: UUID) -> [MCPConnectionRecord] {
        let ids = Set(assignments[agentID.uuidString.lowercased()] ?? [])
        return connections.filter { ids.contains($0.id) }
    }
    public func assignedPrograms(to agentID: UUID) -> [MCPProgramRecord] {
        let ids = Set(assignments[agentID.uuidString.lowercased()] ?? [])
        return programs.filter { ids.contains($0.id) }
    }
    public mutating func assign(_ ids: Set<UUID>, to agentID: UUID) throws {
        let known = Set(connections.map(\.id)).union(programs.map(\.id))
        guard ids.isSubset(of: known) else {
            throw MCPConnectionError.message("One of the selected tool connections no longer exists.")
        }
        assignments[agentID.uuidString.lowercased()] = ids.sorted { $0.uuidString < $1.uuidString }
    }
    public mutating func remove(_ id: UUID) {
        connections.removeAll { $0.id == id }
        programs.removeAll { $0.id == id }
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
    // removals and reloads.
    private mutating func normalizeSkillNames() {
        let reserved = Set(connections.map(\.skillName)).union(programs.map(\.skillName))
        var used: Set<String> = []
        for index in connections.indices {
            connections[index].skillName = Self.uniqueSkill(connections[index].skillName, used: &used, reserved: reserved)
        }
        for index in programs.indices {
            programs[index].allocateSkillName(Self.uniqueSkill(programs[index].skillName, used: &used, reserved: reserved))
        }
    }
    private static func uniqueSkill(_ stem: String, used: inout Set<String>, reserved: Set<String>) -> String {
        var candidate = stem
        var number = 2
        while used.contains(candidate) || (stem != candidate && reserved.contains(candidate)) {
            candidate = String(stem.prefix(52)) + "-\(number)"
            number += 1
        }
        used.insert(candidate)
        return candidate
    }
    private func validate() throws {
        let ids = connections.map(\.id) + programs.map(\.id)
        guard Set(ids).count == ids.count else {
            throw MCPConnectionError.message("Duplicate MCP connection identifiers.")
        }
        for connection in connections {
            _ = try ConversationName.validated(connection.name)
            _ = try MCPConnectionRecord.validatedEndpoint(connection.endpoint)
            guard Self.validSkill(connection.skillName),
                  connection.description.count <= 1_000, connection.instructions.count <= 20_000,
                  (connection.iconData?.count ?? 0) <= 131_072 else {
                throw MCPConnectionError.message("Invalid saved MCP connection.")
            }
        }
        for program in programs {
            _ = try ConversationName.validated(program.name)
            _ = try MCPProgramRecord.validatedExecutable(program.executable)
            _ = try program.arguments.map(MCPProgramRecord.validatedArgument)
            _ = try MCPProgramRecord.validatedNames(program.environmentNames)
            guard Self.validSkill(program.skillName),
                  program.description.count <= 1_000, program.instructions.count <= 20_000 else {
                throw MCPConnectionError.message("Invalid saved MCP connection.")
            }
        }
    }
    private static func validSkill(_ name: String) -> Bool {
        name.hasPrefix("mcp-") && name.count > 4 && name.utf8.count <= 64
            && name.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0) }
    }
}
