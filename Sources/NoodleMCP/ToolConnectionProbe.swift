#if canImport(Security)
import Foundation
import NoodleCore
import Security

/// For a developer's tool probe, never an app: a tool connection service over what an app keeps in the login
/// Keychain, which reads that and never writes it. macOS asks before each item is read, as the items trust only the
/// app that saved them; each is read once. Requests go through the service as they do in the app, so a probe tries
/// the same code.
@_spi(ToolProbe) public struct ToolConnectionProbe: Sendable {
    /// What a saved item says of the connection it was given for.
    public struct Saved: Sendable {
        public let id: UUID
        /// The client a sign-in was made with, for a tool whose organisation brings its own.
        public let clientID: String?
    }

    let namespace: String
    let service: ToolConnectionService
    private let signIns: ReadOnlyKeychainStore<MCPCredentials>
    private let tokens: ReadOnlyKeychainStore<ConnectionToken>
    private let clients: ReadOnlyKeychainStore<ConnectionClientSecret>
    private let awsKeys: ReadOnlyKeychainStore<ConnectionAWSKey>

    public init(namespace: String) {
        self.namespace = namespace
        signIns = ReadOnlyKeychainStore(service: namespace + ".mcp.oauth")
        tokens = ReadOnlyKeychainStore(service: namespace + ".mcp.token")
        clients = ReadOnlyKeychainStore(service: namespace + ".mcp.client")
        awsKeys = ReadOnlyKeychainStore(service: namespace + ".mcp.aws")
        service = ToolConnectionService(credentials: signIns, tokens: tokens, clients: clients, awsKeys: awsKeys,
                                        oauth: MCPOAuth(), httpConfiguration: ToolConnectionService.guardedConfiguration,
                                        // An app's items are kept under its bundle ID, which its sign-ins return to.
                                        bundleIdentifier: namespace)
    }

    public func useAdapters(_ adapters: [String: any ToolConnectionAdapter]) async {
        await service.useAdapters(adapters)
    }

    /// The saved item `connection` would prove itself with: the one under `id`, or else the first given for its
    /// address. Listing the items asks nothing; reading each asks the person first.
    public func saved(for connection: ToolConnection, id: UUID? = nil) throws -> Saved? {
        for candidate in id.map({ [$0] }) ?? savedIDs(store(for: connection)) {
            let item: (endpoint: URL, clientID: String?)? = switch store(for: connection) {
            case tokens.name: try tokens.load(candidate).map { ($0.endpoint, nil) }
            case clients.name: try clients.load(candidate).map { ($0.endpoint, nil) }
            case awsKeys.name: try awsKeys.load(candidate).map { ($0.endpoint, nil) }
            default: try signIns.load(candidate).map { ($0.endpoint, $0.clientID) }
            }
            if let item, item.endpoint == connection.endpoint { return Saved(id: candidate, clientID: item.clientID) }
        }
        return nil
    }

    /// A request as the app makes it. A sign-in whose access token has expired is renewed only where its refresh
    /// token outlives the renewal, as Google's does: elsewhere the service hands out a new one and retires the old,
    /// and as nothing here is saved, the app would be left holding the retired one.
    public func perform(_ request: MCPBridgeRequest, connection: ToolConnection) async throws -> Data {
        if store(for: connection) == signIns.name, let saved = try signIns.load(connection.id),
           (saved.expiresAt ?? .distantPast) < Date().addingTimeInterval(120), saved.issuer.host != "accounts.google.com" {
            throw ToolConnectionError.message("The sign-in's access token has expired. Use the tool once in the app so it renews it, then try again.")
        }
        return try await service.perform(request, connection: connection)
    }

    private func store(for connection: ToolConnection) -> String {
        if connection.awsSigning != nil { return awsKeys.name }
        if connection.clientCredentials != nil { return clients.name }
        if connection.usesToken { return tokens.name }
        return signIns.name
    }

    private func savedIDs(_ store: String) -> [UUID] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: store,
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess, let list = items as? [[String: Any]] else { return [] }
        return list.compactMap { ($0[kSecAttrAccount as String] as? String).flatMap(UUID.init(uuidString:)) }
    }
}

/// An app's Keychain items, read once each and never written: what the service would save, such as a renewed token,
/// is let go, so the app's own items stay exactly as the app left them.
final class ReadOnlyKeychainStore<Value: Codable & Sendable>: @unchecked Sendable {
    let name: String
    private let store: ConnectionKeychainStore<Value>
    private let lock = NSLock()
    private var read: [UUID: Value?] = [:]
    init(service: String) { name = service; store = ConnectionKeychainStore(service: service, label: "") }
    func load(_ id: UUID) throws -> Value? {
        if let value = lock.withLock({ read[id] }) { return value }
        let value = try store.load(id)
        lock.withLock { read[id] = .some(value) }
        return value
    }
    func save(_ value: Value, id: UUID) {}
    func remove(_ id: UUID) {}
}
extension ReadOnlyKeychainStore: MCPCredentialStorage where Value == MCPCredentials {}
extension ReadOnlyKeychainStore: ConnectionTokenStorage where Value == ConnectionToken {}
extension ReadOnlyKeychainStore: ConnectionClientSecretStorage where Value == ConnectionClientSecret {}
extension ReadOnlyKeychainStore: ConnectionAWSKeyStorage where Value == ConnectionAWSKey {}
#endif
