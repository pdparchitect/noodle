import Foundation
import MailBridge
import Security

/// Where mailbox passwords live. Only Noodle Mail reads them; nothing else gets a copy.
public protocol MailSecretStorage: Sendable {
    func password(for mailbox: UUID) throws -> String?
    /// Whether a password is stored, without reading it.
    func hasPassword(for mailbox: UUID) -> Bool
    /// Stores the password; nil or an empty string removes it.
    func setPassword(_ password: String?, for mailbox: UUID) throws
}

/// One login Keychain item per mailbox: service `<Noodle Mail bundle id>.mailbox`, account = the mailbox id.
/// The data-protection keychain refuses these builds without a provisioning profile (-34018), as it does Applet.
public struct MailKeychain: MailSecretStorage {
    public let service: String
    public init(service: String = MailBuildIdentity.current.providerID + ".mailbox") { self.service = service }

    private func item(_ mailbox: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: mailbox.uuidString]
    }
    public func password(for mailbox: UUID) throws -> String? {
        var query = item(mailbox)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw MailError("The Keychain refused the mailbox password (\(status)).")
        }
        return password
    }
    public func hasPassword(for mailbox: UUID) -> Bool {
        var query = item(mailbox)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }
    public func setPassword(_ password: String?, for mailbox: UUID) throws {
        guard let password, !password.isEmpty else {
            let status = SecItemDelete(item(mailbox) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw MailError("The Keychain refused to remove the password (\(status)).") }
            return
        }
        let data = Data(password.utf8)
        var status = SecItemUpdate(item(mailbox) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = item(mailbox)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Noodle Mail mailbox password"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw MailError("The Keychain refused to store the password (\(status)).") }
    }
}
