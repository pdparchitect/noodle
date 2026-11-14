import Foundation

/// Where a connection that proves itself with a client ID and secret exchanges them for an access token.
/// The ID and secret themselves are kept in Keychain.
public struct MCPClientCredentials: Codable, Equatable, Sendable {
    public let tokenEndpoint: URL
    /// What to ask for, space-separated, when the service wants it named.
    public let scope: String?
    public init(tokenEndpoint: URL, scope: String?) {
        self.tokenEndpoint = tokenEndpoint
        let scope = scope?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.scope = scope?.isEmpty == false ? scope : nil
    }
}

/// One user-authorized account, not one unique endpoint. URLs are never keys.
public struct MCPConnectionRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let endpoint: URL
    public var description: String
    public var instructions: String
    public fileprivate(set) var skillName: String
    public var iconData: Data?
    /// The request header a token connection sends its token in, such as Authorization or x-apikey.
    /// Nil for a connection that signs in through the browser. The token itself is kept in Keychain.
    public var tokenHeader: String?
    /// A word the token follows in its header, such as SSWS; nil sends the token alone, or as a bearer
    /// token in Authorization.
    public var tokenScheme: String?
    /// Set for a connection that proves itself with a client ID and secret instead of signing in.
    public var clientCredentials: MCPClientCredentials?
    /// The app adapter that answers for it, in place of an MCP server at `endpoint`, which is then the
    /// address of the service the adapter calls. Only the app that has that adapter serves it.
    public var adapter: String?
    /// The catalogue preset it was made from, if any.
    public var catalogueID: String?
    /// What was filled in for the preset's fields, such as its domain; nil when it has none.
    public var settings: [String: String]?

    public init(id: UUID = UUID(), name: String, endpoint: URL,
                description: String = "", instructions: String = "", tokenHeader: String? = nil, tokenScheme: String? = nil,
                clientCredentials: MCPClientCredentials? = nil, adapter: String? = nil) throws {
        self.id = id
        self.tokenScheme = try tokenScheme.map(Self.validatedTokenScheme)
        guard tokenScheme == nil || tokenHeader != nil else {
            throw MCPConnectionError.message("A token scheme needs a token header.")
        }
        self.adapter = try adapter.map(Self.validatedAdapter)
        self.tokenHeader = try tokenHeader.map(Self.validatedTokenHeader)
        self.clientCredentials = try clientCredentials.map(Self.validatedClientCredentials)
        guard tokenHeader == nil || clientCredentials == nil else {
            throw MCPConnectionError.message("A connection uses either a token or a client ID and secret, not both.")
        }
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

    /// A header name a token may go in: letters, digits and the other characters HTTP allows in a name,
    /// never one that frames the request or carries the browser's own credentials.
    public static func validatedTokenHeader(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespaces)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~")
        let reserved: Set = ["host", "content-length", "content-type", "transfer-encoding", "connection", "cookie",
                             "accept", "mcp-session-id", "mcp-protocol-version"]
        guard !name.isEmpty, name.count <= 100, name.unicodeScalars.allSatisfy(allowed.contains),
              !reserved.contains(name.lowercased()) else {
            throw MCPConnectionError.message("Enter the header the service expects the token in, such as Authorization or x-apikey.")
        }
        return name
    }

    /// A token scheme: one word of letters, digits and hyphens.
    public static func validatedTokenScheme(_ scheme: String) throws -> String {
        guard (1...32).contains(scheme.count), scheme.unicodeScalars.allSatisfy(
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-").contains) else {
            throw MCPConnectionError.message("Invalid token scheme.")
        }
        return scheme
    }

    /// An adapter's name: lowercase letters, digits and hyphens.
    public static func validatedAdapter(_ name: String) throws -> String {
        guard (1...64).contains(name.count),
              name.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains) else {
            throw MCPConnectionError.message("Invalid tool adapter.")
        }
        return name
    }

    public static func validatedClientCredentials(_ credentials: MCPClientCredentials) throws -> MCPClientCredentials {
        guard (credentials.scope?.count ?? 0) <= 1_000 else { throw MCPConnectionError.message("The scope is too long.") }
        return MCPClientCredentials(tokenEndpoint: try validatedEndpoint(credentials.tokenEndpoint), scope: credentials.scope)
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
    // removals and reloads.
    private mutating func normalizeSkillNames() {
        let reserved = Set(connections.map(\.skillName))
        var used: Set<String> = []
        for index in connections.indices {
            let stem = connections[index].skillName
            var candidate = stem
            var number = 2
            while used.contains(candidate) || (stem != candidate && reserved.contains(candidate)) {
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
            if let header = connection.tokenHeader, try MCPConnectionRecord.validatedTokenHeader(header) != header {
                throw MCPConnectionError.message("Invalid saved MCP connection.")
            }
            if let credentials = connection.clientCredentials {
                guard connection.tokenHeader == nil, try MCPConnectionRecord.validatedClientCredentials(credentials) == credentials else {
                    throw MCPConnectionError.message("Invalid saved MCP connection.")
                }
            }
            if let adapter = connection.adapter { _ = try MCPConnectionRecord.validatedAdapter(adapter) }
            if let scheme = connection.tokenScheme {
                guard connection.tokenHeader != nil, try MCPConnectionRecord.validatedTokenScheme(scheme) == scheme else {
                    throw MCPConnectionError.message("Invalid saved MCP connection.")
                }
            }
            guard (connection.catalogueID?.count ?? 0) <= 100, (connection.settings?.count ?? 0) <= 20,
                  connection.settings?.allSatisfy({ $0.key.count <= 100 && $0.value.count <= 400 }) ?? true else {
                throw MCPConnectionError.message("Invalid saved MCP connection.")
            }
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
