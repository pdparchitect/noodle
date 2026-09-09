import Foundation
import Security
@testable import NoodleMCP

// Only disposable, synthetic credentials in this signed fixture's own namespace.
// Invoked twice to check that a new process can read the saved item.
enum MCPKeychainChecks {
    static func run(phase: String, id: UUID) throws {
        let store = MCPCredentialStore(service: "com.pdparchitect.noodle.mcp-fixture.keychain-tests")
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: store.service, kSecAttrAccount as String: id.uuidString.lowercased()]
        if phase == "cleanup" { try store.remove(id); return }
        let endpoint = URL(string: "https://example.com/mcp")!
        var credentials = MCPCredentials(endpoint: endpoint, issuer: endpoint,
            authorizationEndpoint: endpoint, tokenEndpoint: endpoint, clientID: "fixture-client",
            redirectURI: URL(string: "noodle-mcp-test://oauth/callback")!, resource: endpoint,
            scope: "fixture", accessToken: "synthetic-access", refreshToken: "synthetic-refresh",
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
        if phase == "seed" {
            guard try store.load(id) == nil else { throw failure("Fixture ID already exists") }
            try store.save(credentials, id: id)
            return
        }
        guard phase == "verify" else { throw failure("Unknown fixture phase") }
        defer { try? store.remove(id) }
        guard try store.load(id)?.refreshToken == credentials.refreshToken else {
            throw failure("Credentials did not survive a process restart")
        }
        let originalRef = try persistentReference(query)
        // Model an existing item with its own metadata. Refresh must update data
        // in place, not delete/recreate the item or reset its access attributes.
        try success(SecItemUpdate(query as CFDictionary,
            [kSecAttrLabel as String: "Existing fixture label"] as CFDictionary))
        credentials.refreshToken = "synthetic-rotated-refresh"
        try store.save(credentials, id: id)
        guard try store.load(id)?.refreshToken == credentials.refreshToken,
              try persistentReference(query) == originalRef else {
            throw failure("Refresh did not preserve the existing item")
        }
        var attributesQuery = query
        attributesQuery[kSecReturnAttributes as String] = true
        var attributes: CFTypeRef?
        try success(SecItemCopyMatching(attributesQuery as CFDictionary, &attributes))
        guard (attributes as? [String: Any])?[kSecAttrLabel as String] as? String == "Existing fixture label" else {
            throw failure("Refresh changed existing item metadata")
        }
        try store.remove(id)
        guard try store.load(id) == nil else { throw failure("Deleted fixture remains readable") }
        try store.remove(id)
        print("MCP Keychain checks passed: create, cross-process read, in-place token rotation, metadata preservation and deletion")
    }

    private static func persistentReference(_ query: [String: Any]) throws -> Data {
        var query = query
        query[kSecReturnPersistentRef as String] = true
        var value: CFTypeRef?
        try success(SecItemCopyMatching(query as CFDictionary, &value))
        guard let data = value as? Data else { throw failure("Missing fixture reference") }
        return data
    }
    private static func success(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw failure("Keychain fixture OSStatus \(status)") }
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "MCPKeychainChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
