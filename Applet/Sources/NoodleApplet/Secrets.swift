import AppletBridge
import AppletCore
import Foundation
import Security

protocol AppletSecretStorage: Sendable {
  func load(_ account: String) throws -> [String: String]
  func save(_ values: [String: String], account: String) throws
  func accounts() throws -> [String]
}

/// One login Keychain item per noodlet. An HTML noodlet can only reach its own
/// through the bridge. A native noodlet inherits Applet's Keychain identity, so
/// for native code this separates noodlets by convention, not by enforcement.
struct AppletKeychain: AppletSecretStorage {
  let service = AppletBuildIdentity.current.providerID + ".secrets"
  // The data protection Keychain would keep native noodlets out, but it refuses
  // Applet (-34018) without a provisioning profile, which these builds do not have.
  private var base: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
  }
  private func query(_ account: String) -> [String: Any] {
    base.merging([kSecAttrAccount as String: account]) { _, new in new }
  }
  func load(_ account: String) throws -> [String: String] {
    var query = query(account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return [:] }
    guard status == errSecSuccess, let data = item as? Data else { throw Self.failure(status) }
    return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
  }
  func save(_ values: [String: String], account: String) throws {
    if values.isEmpty {
      let status = SecItemDelete(query(account) as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.failure(status) }
      return
    }
    let data = try JSONEncoder().encode(values)
    var status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var addition = query(account)
      addition[kSecValueData as String] = data
      addition[kSecAttrLabel as String] = "Noodle Applet secrets"
      status = SecItemAdd(addition as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw Self.failure(status) }
  }
  func accounts() throws -> [String] {
    let query = base.merging([
      kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll,
    ]) { _, new in new }
    var items: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &items)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess else { throw Self.failure(status) }
    return (items as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
  }
  private static func failure(_ status: OSStatus) -> AppletError {
    AppletError("Keychain could not save or read this secret (OSStatus \(status)).")
  }
}

/// The secrets API shared by HTML and Swift noodlets.
struct AppletSecrets: Sendable {
  static let shared = AppletSecrets(storage: AppletKeychain())
  let storage: any AppletSecretStorage

  /// Test runs keep their own secrets, like their own data.
  static func account(_ package: NoodletPackage, dataRoot: URL) -> String {
    "\(package.key).\(dataRoot.lastPathComponent == "Testing" ? "test" : "user")"
  }
  /// `action` is get, set, delete or names. Returns a JSON value for the noodlet.
  func perform(_ action: String, name: String?, value: String?, account: String) throws -> Any {
    var values = try storage.load(account)
    if action == "names" { return values.keys.sorted() }
    guard let name, !name.isEmpty, name.utf8.count <= 128 else {
      throw AppletError("A secret needs a name of 1–128 bytes.")
    }
    switch action {
    case "get": return values[name] ?? NSNull()
    case "set":
      guard let value, value.utf8.count <= 16384 else { throw AppletError("A secret must fit in 16 KiB.") }
      guard values[name] != nil || values.count < 64 else { throw AppletError("A noodlet may keep 64 secrets.") }
      values[name] = value
    case "delete": values[name] = nil
    default: throw AppletError("Unknown secrets operation.")
    }
    try storage.save(values, account: account)
    return true
  }
  /// Every noodlet's secret names, by account, for Settings. Values are never listed.
  func names() -> [String: [String]] {
    var names: [String: [String]] = [:]
    for account in (try? storage.accounts()) ?? [] {
      let keys = ((try? storage.load(account)) ?? [:]).keys.sorted()
      if !keys.isEmpty { names[account] = keys }
    }
    return names
  }
}
