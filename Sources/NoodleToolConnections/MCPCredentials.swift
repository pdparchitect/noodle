import Foundation
import ProductIdentity
#if canImport(Security)
import Security
#endif

struct MCPCredentials: Codable, Sendable {
    let endpoint: URL
    let issuer: URL
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let clientID: String
    /// Where the app receives the result; callbacks are checked against it.
    let redirectURI: URL
    /// The address registered with the service when it differs from `redirectURI`:
    /// a usenoodle.app page that hands the result to the app.
    var relayURI: URL? = nil
    /// Where the service revokes this sign-in, when it says so; nil for one signed in before it was kept.
    var revocationEndpoint: URL? = nil
    let resource: URL
    let scope: String?
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Date?
}

/// A token a connection sends as it is, for a service that hands out keys rather than signing in.
struct ConnectionToken: Codable, Sendable {
    /// The endpoint it was given for; a connection now pointing elsewhere never sends it.
    let endpoint: URL
    let header: String
    let value: String
}

/// A client ID and secret, with the access token last exchanged for them while it lasts.
struct ConnectionClientSecret: Codable, Sendable {
    /// What they were given for; a connection now pointing elsewhere never sends them.
    let endpoint: URL
    let tokenEndpoint: URL
    let clientID: String
    let clientSecret: String
    var accessToken: String?
    var expiresAt: Date?
}

/// Short-lived AWS keys for one role in one account: their ID, secret, session token and when they expire. They are
/// held only while the app runs, never kept.
struct ConnectionAWSKey: Sendable {
    let accessKeyID: String
    let secretAccessKey: String
    let sessionToken: String?
    var expiresAt: Date? = nil
}

/// An IAM Identity Center sign-in: the client registered for it, and the tokens the person's approval brought.
struct ConnectionAWSSession: Codable, Sendable {
    /// The start URL it was signed in at; a connection now pointing elsewhere never uses it.
    let startURL: URL
    /// The region the organisation's Identity Center is in.
    let region: String
    let client: AWSIdentityCenter.Client
    var accessToken: String?
    var expiresAt: Date?
    var refreshToken: String?
}

/// Where Identity Center sign-ins are kept, apart from other secrets.
protocol ConnectionAWSSessionStorage: Sendable {
    func load(_ id: UUID) throws -> ConnectionAWSSession?
    func save(_ session: ConnectionAWSSession, id: UUID) throws
    func remove(_ id: UUID) throws
}

/// Identity Center sign-ins kept only while the process runs, for a service made without Keychain, as in tests.
final class MemoryConnectionAWSSessions: ConnectionAWSSessionStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [UUID: ConnectionAWSSession] = [:]
    func load(_ id: UUID) -> ConnectionAWSSession? { lock.withLock { sessions[id] } }
    func save(_ session: ConnectionAWSSession, id: UUID) { lock.withLock { sessions[id] = session } }
    func remove(_ id: UUID) { _ = lock.withLock { sessions.removeValue(forKey: id) } }
}

/// Only linked into the app-side MCP client, never the agent's CLI.
protocol MCPCredentialStorage: Sendable {
    func load(_ id: UUID) throws -> MCPCredentials?
    func save(_ credentials: MCPCredentials, id: UUID) throws
    func remove(_ id: UUID) throws
}

/// Where tokens are kept, apart from sign-ins.
protocol ConnectionTokenStorage: Sendable {
    func load(_ id: UUID) throws -> ConnectionToken?
    func save(_ token: ConnectionToken, id: UUID) throws
    func remove(_ id: UUID) throws
}
/// Where client IDs and secrets are kept, apart from sign-ins and tokens.
protocol ConnectionClientSecretStorage: Sendable {
    func load(_ id: UUID) throws -> ConnectionClientSecret?
    func save(_ secret: ConnectionClientSecret, id: UUID) throws
    func remove(_ id: UUID) throws
}

/// Client secrets kept only while the process runs, for a service made without Keychain, as in tests.
final class MemoryConnectionClientSecrets: ConnectionClientSecretStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [UUID: ConnectionClientSecret] = [:]
    func load(_ id: UUID) -> ConnectionClientSecret? { lock.withLock { secrets[id] } }
    func save(_ secret: ConnectionClientSecret, id: UUID) { lock.withLock { secrets[id] = secret } }
    func remove(_ id: UUID) { _ = lock.withLock { secrets.removeValue(forKey: id) } }
}

/// Tokens kept only while the process runs, for a service made without Keychain, as in tests.
final class MemoryConnectionTokens: ConnectionTokenStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [UUID: ConnectionToken] = [:]
    func load(_ id: UUID) -> ConnectionToken? { lock.withLock { tokens[id] } }
    func save(_ token: ConnectionToken, id: UUID) { lock.withLock { tokens[id] = token } }
    func remove(_ id: UUID) { _ = lock.withLock { tokens.removeValue(forKey: id) } }
}
#if canImport(Security)
/// One Keychain item per connection under `service`, holding a sign-in or a token.
struct ConnectionKeychainStore<Value: Codable & Sendable>: Sendable {
    let service: String
    let label: String
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString.lowercased()]
    }
    func load(_ id: UUID) throws -> Value? {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw ToolConnectionServiceError.keychain(status) }
        return try JSONDecoder().decode(Value.self, from: data)
    }
    func save(_ value: Value, id: UUID) throws {
        let data = try JSONEncoder().encode(value)
        // The label goes too, so an item saved under an older name takes the current one.
        let fields = [kSecValueData as String: data, kSecAttrLabel as String: label] as CFDictionary
        let status = SecItemUpdate(query(id) as CFDictionary, fields)
        if status == errSecItemNotFound {
            var addition = query(id)
            addition[kSecValueData as String] = data
            // Keep the login Keychain used by existing installations. Omitting
            // kSecAttrAccess lets Keychain create its default calling-app ACL;
            // no deprecated SecAccess/SecTrustedApplication setup is needed.
            // Updates above change only the data and label, preserving existing item ACLs.
            addition[kSecAttrLabel as String] = label
            let added = SecItemAdd(addition as CFDictionary, nil)
            guard added == errSecSuccess else { throw ToolConnectionServiceError.keychain(added) }
        } else if status != errSecSuccess { throw ToolConnectionServiceError.keychain(status) }
    }
    func remove(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ToolConnectionServiceError.keychain(status) }
    }
}
extension ConnectionKeychainStore: MCPCredentialStorage where Value == MCPCredentials {}
extension ConnectionKeychainStore: ConnectionTokenStorage where Value == ConnectionToken {}
extension ConnectionKeychainStore: ConnectionClientSecretStorage where Value == ConnectionClientSecret {}
extension ConnectionKeychainStore: ConnectionAWSSessionStorage where Value == ConnectionAWSSession {}
#else
/// Where there is no keychain there is nowhere yet to keep a sign-in: none is found, and none is kept.
struct NoConnectionCredentials: MCPCredentialStorage, ConnectionTokenStorage, ConnectionClientSecretStorage, ConnectionAWSSessionStorage {
    func load(_ id: UUID) throws -> ConnectionAWSSession? { nil }
    func save(_ session: ConnectionAWSSession, id: UUID) throws { throw ToolConnectionServiceError.credentialStorage }
    func load(_ id: UUID) throws -> ConnectionClientSecret? { nil }
    func save(_ secret: ConnectionClientSecret, id: UUID) throws { throw ToolConnectionServiceError.credentialStorage }
    func load(_ id: UUID) throws -> MCPCredentials? { nil }
    func save(_ credentials: MCPCredentials, id: UUID) throws { throw ToolConnectionServiceError.credentialStorage }
    func load(_ id: UUID) throws -> ConnectionToken? { nil }
    func save(_ token: ConnectionToken, id: UUID) throws { throw ToolConnectionServiceError.credentialStorage }
    func remove(_ id: UUID) throws {}
}
#endif

public enum ToolConnectionServiceError: LocalizedError, Sendable {
    case credentialStorage, signInRequired, registrationUnsupported, invalidMetadata, invalidCallback
    case network(Int), timedOut, revoked, responseTooLarge
    /// The organisation managing this Mac doesn't allow the connection.
    case notAllowed
    /// The service's own `error` and optional `error_description` from a callback whose state matched.
    case authorizationRefused(code: String, reason: String?)
    case keychain(Int32)
    public var errorDescription: String? {
        switch self {
        case .credentialStorage: return "Could not securely save or read this connection in Keychain."
        case .keychain(let code): return "Keychain could not save or read this connection (OSStatus \(code))."
        case .signInRequired: return "Reconnect this connection in Settings → Tools."
        case .registrationUnsupported: return "This MCP does not support automatic OAuth client registration."
        case .invalidMetadata: return "The server returned unsupported or inconsistent OAuth metadata."
        case .invalidCallback: return "The sign-in response could not be verified. Please try connecting again."
        case .authorizationRefused(let code, nil): return "The service refused the sign-in (\(code))."
        case .authorizationRefused(let code, let reason?): return "The service refused the sign-in: \(reason) (\(code))"
        case .network(401): return "The service rejected this sign-in (HTTP 401). Connect again to renew access."
        case .network(403): return "The service refused access (HTTP 403). Its administrator needs to check that the MCP API is enabled and this account has permission to use it."
        case .network(404): return "The MCP endpoint was not found (HTTP 404). Check the connection URL."
        case .network(429): return "The service is rate limiting requests (HTTP 429). Try again later."
        case .network(let status): return "The MCP service could not complete the request (HTTP \(status))."
        case .timedOut: return "The MCP request timed out. A remote action may have completed; verify before retrying."
        case .revoked: return "This connection was removed or disconnected."
        case .responseTooLarge: return "The MCP response exceeded the supported size."
        case .notAllowed: return "Your organisation doesn't allow this tool connection."
        }
    }
}
