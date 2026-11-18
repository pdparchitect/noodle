import Foundation

/// Where a connection that proves itself with a client ID and secret exchanges them for an access token.
/// The ID and secret themselves are kept in Keychain.
public struct ConnectionClientCredentials: Codable, Equatable, Sendable {
    public let tokenEndpoint: URL
    /// What to ask for, space-separated, when the service wants it named.
    public let scope: String?
    /// Fields the service wants in the exchange besides the standard ones, such as an audience.
    public let parameters: [String: String]?
    public init(tokenEndpoint: URL, scope: String?, parameters: [String: String]? = nil) {
        self.tokenEndpoint = tokenEndpoint
        let scope = scope?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.scope = scope?.isEmpty == false ? scope : nil
        self.parameters = parameters?.isEmpty == false ? parameters : nil
    }
}

/// For a connection that signs its requests to AWS with an access key: the region it works in unless a request
/// names another. The key itself is kept in Keychain.
public struct ConnectionAWSSigning: Codable, Equatable, Sendable {
    public let region: String
    public init(region: String) { self.region = region }
}

/// One user-authorized account, not one unique endpoint. URLs are never keys.
public struct ToolConnection: Codable, Identifiable, Equatable, Sendable {
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
    /// The query parameter a token goes in instead of a header, for a service that takes it only in its address.
    public var tokenParameter: String?
    /// Whether it proves itself with a token, in a header or in its address.
    public var usesToken: Bool { tokenHeader != nil || tokenParameter != nil }
    /// A word the token follows in its header, such as SSWS; nil sends the token alone, or as a bearer
    /// token in Authorization.
    public var tokenScheme: String?
    /// Set for a connection that proves itself with a client ID and secret instead of signing in.
    public var clientCredentials: ConnectionClientCredentials?
    /// Set for a connection that signs its requests to AWS with an access key instead of sending a token.
    public var awsSigning: ConnectionAWSSigning?
    /// Whether it proves itself with a secret kept in Keychain: a token, a client ID and secret or an AWS key.
    public var keepsSecret: Bool { usesToken || clientCredentials != nil || awsSigning != nil }
    /// The app adapter that answers for it, in place of an MCP server at `endpoint`, which is then the
    /// address of the service the adapter calls. Only the app that has that adapter serves it.
    public var adapter: String?
    /// The catalogue preset it was made from, if any.
    public var catalogueID: String?
    /// What was filled in for the preset's fields, such as its domain; nil when it has none.
    public var settings: [String: String]?

    /// This account as its preset makes it from new details, such as another address or organisation: what `fresh`
    /// says it reaches and how, keeping the name bots know it by, its icon and the person's own text.
    public func remade(as fresh: ToolConnection) -> ToolConnection {
        var record = fresh
        record.skillName = skillName
        record.iconData = iconData
        record.name = name
        record.description = description
        record.instructions = instructions
        return record
    }

    public init(id: UUID = UUID(), name: String, endpoint: URL,
                description: String = "", instructions: String = "", tokenHeader: String? = nil, tokenScheme: String? = nil,
                tokenParameter: String? = nil, clientCredentials: ConnectionClientCredentials? = nil, awsSigning: ConnectionAWSSigning? = nil,
                adapter: String? = nil) throws {
        self.id = id
        self.awsSigning = try awsSigning.map(Self.validatedAWSSigning)
        guard awsSigning == nil || (tokenHeader == nil && tokenParameter == nil && clientCredentials == nil) else {
            throw ToolConnectionError.message("A connection signs with an AWS key or uses another sign-in, not both.")
        }
        self.tokenParameter = try tokenParameter.map(Self.validatedTokenParameter)
        guard tokenHeader == nil || tokenParameter == nil else {
            throw ToolConnectionError.message("A token goes in a header or in the address, not both.")
        }
        self.tokenScheme = try tokenScheme.map(Self.validatedTokenScheme)
        guard tokenScheme == nil || tokenHeader != nil else {
            throw ToolConnectionError.message("A token scheme needs a token header.")
        }
        self.adapter = try adapter.map(Self.validatedAdapter)
        self.tokenHeader = try tokenHeader.map(Self.validatedTokenHeader)
        self.clientCredentials = try clientCredentials.map(Self.validatedClientCredentials)
        guard (tokenHeader == nil && tokenParameter == nil) || clientCredentials == nil else {
            throw ToolConnectionError.message("A connection uses either a token or a client ID and secret, not both.")
        }
        self.name = try ConversationName.validated(name)
        self.endpoint = try Self.validatedEndpoint(endpoint, adapter: self.adapter)
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
            throw ToolConnectionError.message("Enter the header the service expects the token in, such as Authorization or x-apikey.")
        }
        return name
    }

    /// An AWS region's name, such as eu-west-1.
    public static func validatedAWSSigning(_ signing: ConnectionAWSSigning) throws -> ConnectionAWSSigning {
        guard (1...32).contains(signing.region.count),
              signing.region.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains) else {
            throw ToolConnectionError.message("Invalid AWS region.")
        }
        return signing
    }

    /// A query parameter's name: letters, digits, hyphens and underscores.
    public static func validatedTokenParameter(_ name: String) throws -> String {
        guard (1...64).contains(name.count), name.unicodeScalars.allSatisfy(
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains) else {
            throw ToolConnectionError.message("Invalid token parameter.")
        }
        return name
    }

    /// A token scheme: one word of letters, digits and hyphens.
    public static func validatedTokenScheme(_ scheme: String) throws -> String {
        guard (1...32).contains(scheme.count), scheme.unicodeScalars.allSatisfy(
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-").contains) else {
            throw ToolConnectionError.message("Invalid token scheme.")
        }
        return scheme
    }

    /// An adapter's name: lowercase letters, digits and hyphens.
    public static func validatedAdapter(_ name: String) throws -> String {
        guard (1...64).contains(name.count),
              name.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains) else {
            throw ToolConnectionError.message("Invalid tool adapter.")
        }
        return name
    }

    public static func validatedClientCredentials(_ credentials: ConnectionClientCredentials) throws -> ConnectionClientCredentials {
        guard (credentials.scope?.count ?? 0) <= 1_000 else { throw ToolConnectionError.message("The scope is too long.") }
        let names = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")
        for (name, value) in credentials.parameters ?? [:] {
            guard (1...64).contains(name.count), name.unicodeScalars.allSatisfy(names.contains),
                  !["grant_type", "client_id", "client_secret", "scope"].contains(name), value.count <= 1_000 else {
                throw ToolConnectionError.message("Invalid token exchange field \(name).")
            }
        }
        return ConnectionClientCredentials(tokenEndpoint: try validatedEndpoint(credentials.tokenEndpoint), scope: credentials.scope,
                                    parameters: credentials.parameters)
    }

    public static func validatedEndpoint(_ url: URL) throws -> URL {
        guard url.scheme?.lowercased() == "https", url.fragment == nil,
              let result = MessageLink.publicWebURL(from: url) else {
            throw ToolConnectionError.message("Enter a public HTTPS server URL without credentials or a fragment.")
        }
        return result
    }

    /// A connection's address. One an app's adapter answers for may also be a service the person runs on this Mac
    /// or the local network, and only there over plain HTTP, where its credentials never cross the internet.
    /// Every other connection, an MCP server's above all, stays at a public HTTPS address.
    public static func validatedEndpoint(_ url: URL, adapter: String?) throws -> URL {
        guard adapter != nil else { return try validatedEndpoint(url) }
        guard url.fragment == nil, let result = MessageLink.webURL(from: url), let host = result.host,
              result.scheme == "https" || isLocalHost(host) else {
            throw ToolConnectionError.message("Enter an HTTPS address, or an HTTP one on this Mac or the local network, without credentials.")
        }
        return result
    }

    /// Whether `host` names this Mac or a machine on the local network: localhost, a .local name, a name alone
    /// such as grafana, or a loopback, private, link-local or carrier-grade NAT address, as Tailscale's are.
    public static func isLocalHost(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        if host.contains(":") {
            return host == "::1" || host.hasPrefix("fc") || host.hasPrefix("fd")
                || ["fe8", "fe9", "fea", "feb"].contains(where: host.hasPrefix)
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = labels.compactMap { UInt8($0) }
        guard octets.count == 4, labels.count == 4 else {
            return labels.count == 1 && octets.isEmpty
        }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168), (169, 254), (172, 16...31), (100, 64...127): return true
        default: return false
        }
    }
}

public enum ToolConnectionError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

public struct ToolConnectionRegistry: Codable, Equatable, Sendable {
    public var connections: [ToolConnection] = []
    public var assignments: [String: [UUID]] = [:]
    public init() {}
    public func assigned(to agentID: UUID) -> [ToolConnection] {
        let ids = Set(assignments[agentID.uuidString.lowercased()] ?? [])
        return connections.filter { ids.contains($0.id) }
    }
    public mutating func assign(_ ids: Set<UUID>, to agentID: UUID) throws {
        guard ids.isSubset(of: Set(connections.map(\.id))) else {
            throw ToolConnectionError.message("One of the selected tool connections no longer exists.")
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
            throw ToolConnectionError.message("The MCP registry directory must not be a symbolic link.")
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
            throw ToolConnectionError.message("Duplicate MCP connection identifiers.")
        }
        for connection in connections {
            _ = try ConversationName.validated(connection.name)
            _ = try ToolConnection.validatedEndpoint(connection.endpoint, adapter: connection.adapter)
            if let header = connection.tokenHeader, try ToolConnection.validatedTokenHeader(header) != header {
                throw ToolConnectionError.message("Invalid saved MCP connection.")
            }
            if let credentials = connection.clientCredentials {
                guard !connection.usesToken, try ToolConnection.validatedClientCredentials(credentials) == credentials else {
                    throw ToolConnectionError.message("Invalid saved MCP connection.")
                }
            }
            if let adapter = connection.adapter { _ = try ToolConnection.validatedAdapter(adapter) }
            if let signing = connection.awsSigning {
                guard !connection.usesToken, connection.clientCredentials == nil,
                      try ToolConnection.validatedAWSSigning(signing) == signing else {
                    throw ToolConnectionError.message("Invalid saved MCP connection.")
                }
            }
            if let parameter = connection.tokenParameter {
                guard connection.tokenHeader == nil, try ToolConnection.validatedTokenParameter(parameter) == parameter else {
                    throw ToolConnectionError.message("Invalid saved MCP connection.")
                }
            }
            if let scheme = connection.tokenScheme {
                guard connection.tokenHeader != nil, try ToolConnection.validatedTokenScheme(scheme) == scheme else {
                    throw ToolConnectionError.message("Invalid saved MCP connection.")
                }
            }
            guard (connection.catalogueID?.count ?? 0) <= 100, (connection.settings?.count ?? 0) <= 20,
                  connection.settings?.allSatisfy({ $0.key.count <= 100 && $0.value.count <= 400 }) ?? true else {
                throw ToolConnectionError.message("Invalid saved MCP connection.")
            }
            guard connection.skillName.hasPrefix("mcp-"), connection.skillName.count > 4,
                  connection.skillName.utf8.count <= 64,
                  connection.skillName.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0) }),
                  connection.description.count <= 1_000, connection.instructions.count <= 20_000,
                  (connection.iconData?.count ?? 0) <= 131_072 else {
                throw ToolConnectionError.message("Invalid saved MCP connection.")
            }
        }
    }
}
