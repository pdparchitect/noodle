import Foundation
import Security

/// Environment values for a launched program. The registry stores names only.
public protocol MCPProgramSecretStorage: Sendable {
    func load(_ id: UUID) throws -> [String: String]
    func save(_ values: [String: String], id: UUID) throws
    func remove(_ id: UUID) throws
}

public final class MCPProgramMemorySecrets: MCPProgramSecretStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: [String: String]] = [:]
    public init() {}
    public func load(_ id: UUID) throws -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return values[id] ?? [:]
    }
    public func save(_ values: [String: String], id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        self.values[id] = values
    }
    public func remove(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        self.values[id] = nil
    }
}

struct MCPProgramKeychain: MCPProgramSecretStorage {
    let service: String
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString.lowercased()]
    }
    func load(_ id: UUID) throws -> [String: String] {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess, let data = item as? Data else { throw MCPServiceError.keychain(status) }
        return try JSONDecoder().decode([String: String].self, from: data)
    }
    func save(_ values: [String: String], id: UUID) throws {
        let data = try JSONEncoder().encode(values)
        let fields = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(query(id) as CFDictionary, fields)
        if status == errSecItemNotFound {
            var addition = query(id)
            addition[kSecValueData as String] = data
            addition[kSecAttrLabel as String] = "Noodle MCP program"
            let added = SecItemAdd(addition as CFDictionary, nil)
            guard added == errSecSuccess else { throw MCPServiceError.keychain(added) }
        } else if status != errSecSuccess { throw MCPServiceError.keychain(status) }
    }
    func remove(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MCPServiceError.keychain(status) }
    }
}
