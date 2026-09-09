import Foundation
import Security

struct MCPCredentials: Codable, Sendable {
    let endpoint: URL
    let issuer: URL
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let clientID: String
    let redirectURI: URL
    let resource: URL
    let scope: String?
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Date?
}

/// Only linked into the app-side MCP client, never the agent's CLI.
protocol MCPCredentialStorage: Sendable {
    func load(_ id: UUID) throws -> MCPCredentials?
    func save(_ credentials: MCPCredentials, id: UUID) throws
    func remove(_ id: UUID) throws
}
struct MCPCredentialStore: MCPCredentialStorage {
    let service: String
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString.lowercased()]
    }
    func load(_ id: UUID) throws -> MCPCredentials? {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw MCPServiceError.keychain(status) }
        return try JSONDecoder().decode(MCPCredentials.self, from: data)
    }
    func save(_ credentials: MCPCredentials, id: UUID) throws {
        let data = try JSONEncoder().encode(credentials)
        let fields = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(query(id) as CFDictionary, fields)
        if status == errSecItemNotFound {
            var addition = query(id)
            addition[kSecValueData as String] = data
            // Noodle is distributed without a provisioning profile. Use the
            // macOS login Keychain and an explicit signed-app ACL, not the
            // profile-gated Data Protection Keychain or an on-disk token file.
            var trusted: SecTrustedApplication?
            let trustedStatus = SecTrustedApplicationCreateFromPath(nil, &trusted)
            guard trustedStatus == errSecSuccess, let trusted else { throw MCPServiceError.keychain(trustedStatus) }
            var access: SecAccess?
            let accessStatus = SecAccessCreate("Noodle MCP connection" as CFString, [trusted] as CFArray, &access)
            guard accessStatus == errSecSuccess, let access else { throw MCPServiceError.keychain(accessStatus) }
            addition[kSecAttrAccess as String] = access
            let added = SecItemAdd(addition as CFDictionary, nil)
            guard added == errSecSuccess else { throw MCPServiceError.keychain(added) }
        } else if status != errSecSuccess { throw MCPServiceError.keychain(status) }
    }
    func remove(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MCPServiceError.keychain(status) }
    }
}

public enum MCPServiceError: LocalizedError, Sendable {
    case credentialStorage, signInRequired, registrationUnsupported, invalidMetadata, invalidCallback
    case network(Int), timedOut, revoked, responseTooLarge
    case keychain(Int32)
    public var errorDescription: String? {
        switch self {
        case .credentialStorage: return "Could not securely save or read this connection in Keychain."
        case .keychain(let code): return "Keychain could not save or read this connection (OSStatus \(code))."
        case .signInRequired: return "Reconnect this connection in Settings → Tools."
        case .registrationUnsupported: return "This MCP does not support automatic OAuth client registration."
        case .invalidMetadata: return "The server returned unsupported or inconsistent OAuth metadata."
        case .invalidCallback: return "The sign-in response could not be verified. Please try connecting again."
        case .network(let status): return "The MCP service could not complete the request (HTTP \(status))."
        case .timedOut: return "The MCP request timed out. A remote action may have completed; verify before retrying."
        case .revoked: return "This connection was removed or disconnected."
        case .responseTooLarge: return "The MCP response exceeded the supported size."
        }
    }
}
