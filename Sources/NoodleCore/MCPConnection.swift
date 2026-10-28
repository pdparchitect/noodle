import Darwin
import Foundation

public enum MCPConnectionPlace: String, Codable, Sendable {
    case remote, loopback
}

public enum MCPLocalAuthorization: String, Codable, Sendable {
    case none, bearer, browser
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
    /// Missing on records written before local connections. Those stay remote.
    public var place: MCPConnectionPlace
    /// Set only for a loopback connection. The secret itself is never stored here.
    public var authorization: MCPLocalAuthorization?
    /// Origin the person allowed, or nil when they have not allowed it.
    public var consentedOrigin: String?

    public init(id: UUID = UUID(), name: String, endpoint: URL,
                description: String = "", instructions: String = "") throws {
        self.id = id
        self.name = try ConversationName.validated(name)
        self.endpoint = try Self.validatedEndpoint(endpoint)
        self.description = String(description.prefix(1_000))
        self.instructions = String(instructions.prefix(20_000))
        self.skillName = Self.skillName(for: name)
        self.place = .remote
        self.authorization = nil
        self.consentedOrigin = nil
    }

    public init(id: UUID = UUID(), name: String, loopback endpoint: URL,
                authorization: MCPLocalAuthorization, consentedOrigin: String? = nil,
                description: String = "", instructions: String = "") throws {
        self.id = id
        self.name = try ConversationName.validated(name)
        let canonical = try Self.validatedLoopbackEndpoint(endpoint)
        self.endpoint = canonical
        self.description = String(description.prefix(1_000))
        self.instructions = String(instructions.prefix(20_000))
        self.skillName = Self.skillName(for: name)
        self.place = .loopback
        self.authorization = authorization
        if let consentedOrigin, consentedOrigin != Self.origin(of: canonical) {
            throw MCPConnectionError.message("The consent does not match this address.")
        }
        self.consentedOrigin = consentedOrigin
    }

    public static func validatedEndpoint(_ url: URL) throws -> URL {
        guard url.scheme?.lowercased() == "https", url.fragment == nil,
              let result = MessageLink.publicWebURL(from: url) else {
            throw MCPConnectionError.message("Enter a public HTTPS server URL without credentials or a fragment.")
        }
        return result
    }

    public static let secretQueryNames: Set<String> = ["token", "key", "secret", "password", "auth", "access_token", "apikey"]

    /// Loopback only. This is not the public-server check, and it does not accept a LAN or public host.
    public static func validatedLoopbackEndpoint(_ url: URL) throws -> URL {
        guard url.absoluteString.count <= 2_048,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let rawHost = components.host?.lowercased(), !rawHost.isEmpty else {
            throw MCPConnectionError.message("Enter a loopback HTTP address without credentials or a fragment.")
        }
        if components.user != nil || components.password != nil {
            throw MCPConnectionError.message("Put the secret in the secure field, not in the address.")
        }
        if components.fragment != nil {
            throw MCPConnectionError.message("Enter a loopback HTTP address without credentials or a fragment.")
        }
        if let items = components.queryItems, items.contains(where: { secretQueryNames.contains($0.name.lowercased()) }) {
            throw MCPConnectionError.message("Put the secret in the secure field, not in the address.")
        }
        guard isLoopbackName(rawHost) else {
            throw MCPConnectionError.message("Local mode accepts loopback only.")
        }
        var canonical = components
        canonical.scheme = scheme
        canonical.host = rawHost
        canonical.fragment = nil
        guard let result = canonical.url else {
            throw MCPConnectionError.message("Enter a loopback HTTP address without credentials or a fragment.")
        }
        return result
    }

    /// The saved address, checked again at connect time against the addresses it resolves to.
    public static func dialURL(_ url: URL, lookup: (String) throws -> [String]) throws -> URL {
        let canonical = try validatedLoopbackEndpoint(url)
        guard let host = canonical.host else {
            throw MCPConnectionError.message("Local mode accepts loopback only.")
        }
        let addresses = try lookup(host)
        guard !addresses.isEmpty, addresses.allSatisfy(isNumericLoopback) else {
            throw MCPConnectionError.message("Local mode accepts loopback only.")
        }
        guard canonical.scheme == "http", !isNumericLoopback(host) else { return canonical }
        let address = addresses[0].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard let dial = httpDial(canonical, host: address) else {
            throw MCPConnectionError.message("Local mode accepts loopback only.")
        }
        return dial
    }

    /// URLComponents cannot build a URL whose host is `::1`. Bracket that address directly.
    private static func httpDial(_ url: URL, host: String) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if !host.contains(":") {
            parts.host = host
            return parts.url
        }
        let shown = "[\(host.replacingOccurrences(of: "%", with: "%25"))]"
        let scheme = parts.scheme ?? "http"
        let port = parts.port.map { ":\($0)" } ?? ""
        let path = parts.percentEncodedPath
        let query = parts.percentEncodedQuery.map { "?\($0)" } ?? ""
        return URL(string: "\(scheme)://\(shown)\(port)\(path)\(query)")
    }

    public static func systemAddresses(for host: String) throws -> [String] {
        if isNumericLoopback(host) {
            return [host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()]
        }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        let code = getaddrinfo(host, nil, &hints, &info)
        guard code == 0, let info else {
            throw MCPConnectionError.message("Local mode accepts loopback only.")
        }
        defer { freeaddrinfo(info) }
        var results: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = info
        while let node = cursor {
            if let address = node.pointee.ai_addr {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, node.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    results.append(String(cString: buffer))
                }
            }
            cursor = node.pointee.ai_next
        }
        return results
    }

    public static func origin(of url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? "http"
        let host = url.host?.lowercased() ?? ""
        let shown = host.contains(":") ? "[\(host)]" : host
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(shown):\(port)"
    }

    public static func isLoopbackName(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return normalized == "localhost" || isNumericLoopback(normalized)
    }

    public static func isNumericLoopback(_ host: String) -> Bool {
        let text = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        // Do not strip at "%". 127.0.0.1%.example.com would then read as 127.0.0.1.
        if text.contains("%") { return false }
        if text.contains(":") { return ipv6Loopback(text) }
        return ipv4Loopback(text)
    }

    /// Four numeric labels, then inet_pton. A name such as 127.0.0.1.example.com has more than four.
    private static func ipv4Loopback(_ text: String) -> Bool {
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count == 4 else { return false }
        guard labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return false }
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return false }
        let value = UInt32(bigEndian: address.s_addr)
        return (value & 0xff00_0000) == 0x7f00_0000
    }

    /// Exactly ::1. An IPv4-mapped address, including ::ffff:127.0.0.1, is not loopback.
    private static func ipv6Loopback(_ text: String) -> Bool {
        if text.contains(".") { return false }
        var address = in6_addr()
        var loopback = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1,
              inet_pton(AF_INET6, "::1", &loopback) == 1 else { return false }
        return withUnsafePointer(to: address) { left in
            withUnsafePointer(to: loopback) { right in
                memcmp(left, right, MemoryLayout<in6_addr>.size) == 0
            }
        }
    }

    private static func skillName(for name: String) -> String {
        let slug = name.lowercased().unicodeScalars.map {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").contains($0) ? String($0) : "-"
        }.joined().split(separator: "-").joined(separator: "-")
        let prefix = String(slug.prefix(20)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "mcp-" + (prefix.isEmpty ? "connection" : prefix)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, endpoint, description, instructions, skillName, iconData, place, authorization, consentedOrigin
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        endpoint = try container.decode(URL.self, forKey: .endpoint)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        instructions = try container.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        skillName = try container.decode(String.self, forKey: .skillName)
        iconData = try container.decodeIfPresent(Data.self, forKey: .iconData)
        place = try container.decodeIfPresent(MCPConnectionPlace.self, forKey: .place) ?? .remote
        authorization = try container.decodeIfPresent(MCPLocalAuthorization.self, forKey: .authorization)
        consentedOrigin = try container.decodeIfPresent(String.self, forKey: .consentedOrigin)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(description, forKey: .description)
        try container.encode(instructions, forKey: .instructions)
        try container.encode(skillName, forKey: .skillName)
        try container.encodeIfPresent(iconData, forKey: .iconData)
        if place != .remote { try container.encode(place, forKey: .place) }
        try container.encodeIfPresent(authorization, forKey: .authorization)
        try container.encodeIfPresent(consentedOrigin, forKey: .consentedOrigin)
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
    /// Local loopback connections. An older build does not read this key, so it never treats one as public.
    public var loopback: [MCPConnectionRecord] = []
    public var all: [MCPConnectionRecord] { connections + loopback }
    public init() {}

    private enum CodingKeys: String, CodingKey { case connections, assignments, loopback }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        connections = try container.decodeIfPresent([MCPConnectionRecord].self, forKey: .connections) ?? []
        assignments = try container.decodeIfPresent([String: [UUID]].self, forKey: .assignments) ?? [:]
        loopback = try container.decodeIfPresent([MCPConnectionRecord].self, forKey: .loopback) ?? []
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(connections, forKey: .connections)
        try container.encode(assignments, forKey: .assignments)
        if !loopback.isEmpty { try container.encode(loopback, forKey: .loopback) }
    }

    public func record(_ id: UUID) -> MCPConnectionRecord? { all.first { $0.id == id } }
    public func assigned(to agentID: UUID) -> [MCPConnectionRecord] {
        let ids = Set(assignments[agentID.uuidString.lowercased()] ?? [])
        return all.filter { ids.contains($0.id) }
    }
    public mutating func assign(_ ids: Set<UUID>, to agentID: UUID) throws {
        guard ids.isSubset(of: Set(all.map(\.id))) else {
            throw MCPConnectionError.message("One of the selected tool connections no longer exists.")
        }
        assignments[agentID.uuidString.lowercased()] = ids.sorted { $0.uuidString < $1.uuidString }
    }
    public mutating func remove(_ id: UUID) {
        connections.removeAll { $0.id == id }
        loopback.removeAll { $0.id == id }
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
        var combined = connections + loopback
        let reserved = Set(combined.map(\.skillName))
        var used: Set<String> = []
        for index in combined.indices {
            let stem = combined[index].skillName
            var candidate = stem
            var number = 2
            while used.contains(candidate) || (stem != candidate && reserved.contains(candidate)) {
                candidate = String(stem.prefix(52)) + "-\(number)"
                number += 1
            }
            combined[index].skillName = candidate
            used.insert(candidate)
        }
        connections = combined.filter { $0.place == .remote }
        loopback = combined.filter { $0.place == .loopback }
    }
    private func validate() throws {
        guard Set(all.map(\.id)).count == all.count else {
            throw MCPConnectionError.message("Duplicate MCP connection identifiers.")
        }
        for connection in connections {
            guard connection.place == .remote, connection.authorization == nil, connection.consentedOrigin == nil else {
                throw MCPConnectionError.message("Invalid saved MCP connection.")
            }
            try Self.checkShared(connection)
            _ = try MCPConnectionRecord.validatedEndpoint(connection.endpoint)
        }
        for connection in loopback {
            guard connection.place == .loopback, let authorization = connection.authorization else {
                throw MCPConnectionError.message("Invalid saved MCP connection.")
            }
            _ = authorization
            try Self.checkShared(connection)
            let canonical = try MCPConnectionRecord.validatedLoopbackEndpoint(connection.endpoint)
            if let consentedOrigin = connection.consentedOrigin, consentedOrigin != MCPConnectionRecord.origin(of: canonical) {
                throw MCPConnectionError.message("Invalid saved MCP connection.")
            }
        }
    }
    private static func checkShared(_ connection: MCPConnectionRecord) throws {
        _ = try ConversationName.validated(connection.name)
        guard connection.skillName.hasPrefix("mcp-"), connection.skillName.count > 4,
              connection.skillName.utf8.count <= 64,
              connection.skillName.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0) }),
              connection.description.count <= 1_000, connection.instructions.count <= 20_000,
              (connection.iconData?.count ?? 0) <= 131_072 else {
            throw MCPConnectionError.message("Invalid saved MCP connection.")
        }
    }
}
