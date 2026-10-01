import AppletCore
import Foundation
import WebKit

/// What each noodlet has saved: its data directory and its WebKit store.
@MainActor enum AppletStorage {
  static func sizes(root: URL) -> [String: Int] {
    let data = root.appendingPathComponent("Data")
    var sizes: [String: Int] = [:]
    for key in (try? FileManager.default.contentsOfDirectory(atPath: data.path)) ?? [] {
      let files = FileManager.default.enumerator(
        at: data.appendingPathComponent(key), includingPropertiesForKeys: [.fileSizeKey])
      var total = 0
      while let file = files?.nextObject() as? URL {
        total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      }
      sizes[key] = total
    }
    return sizes
  }
  static func remove(_ key: String, root: URL, defaults: UserDefaults) async {
    try? FileManager.default.removeItem(at: root.appendingPathComponent("Data/\(key)"))
    // WebKit crashes when removing a store is the first thing a process asks of it, as launch
    // does for a noodlet that is gone. A web view with no website data sets WebKit up first.
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let bootstrap = WKWebView(frame: .zero, configuration: configuration)
    defer { withExtendedLifetime(bootstrap) {} }
    for scope in ["user", "test"] {
      let name = "store.\(key).\(scope)"
      if let id = defaults.string(forKey: name).flatMap(UUID.init(uuidString:)) {
        try? await WKWebsiteDataStore.remove(forIdentifier: id)
      }
      defaults.removeObject(forKey: name)
    }
  }
}

/// A noodlet's data folder and Keychain item on this Mac, as its page reaches them.
struct AppletDataStore: NoodletStore {
  let dataRoot: URL
  let account: String
  let secrets: AppletSecrets

  func perform(_ call: NoodletStoreCall) async throws -> NoodletValue {
    if call.operation == "secret" {
      return try secrets.perform(call.action ?? "", name: call.name, value: call.value, account: account)
    }
    if call.operation == "list" { return .entries(list(prefix: call.path ?? "")) }
    guard let path = call.path else { throw AppletError("A relative data path is required.") }
    let file = try NoodletPath.child(path, in: dataRoot)
    let limit = NoodletStoreCall.fileLimit
    if call.operation == "read" {
      guard FileManager.default.fileExists(atPath: file.path) else { return .null }
      guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= limit else {
        throw AppletError("Data file exceeds 16 MiB.")
      }
      return .text(try Data(contentsOf: file).base64EncodedString())
    }
    guard call.operation == "write" else { throw AppletError("Unknown data operation.") }
    // Base64 is a third larger than the bytes it carries.
    guard let encoded = call.data, encoded.utf8.count <= (limit / 3 + 1) * 4, let bytes = Data(base64Encoded: encoded)
    else { throw AppletError("Data must be base64 within 16 MiB.") }
    guard bytes.count <= limit else { throw AppletError("Data must fit in 16 MiB.") }
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bytes.write(to: file, options: .atomic)
    return .bool(true)
  }

  /// The regular files in the data folder whose path starts with `prefix`, sorted by path.
  /// Links are skipped and never followed.
  func list(prefix: String) -> [NoodletEntry] {
    let root = dataRoot.standardizedFileURL
    let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
    guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
    let dates = ISO8601DateFormatter()
    var entries: [NoodletEntry] = []
    while let file = walk.nextObject() as? URL {
      guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true,
        values.isRegularFile == true
      else { continue }
      let full = file.standardizedFileURL.path
      guard full.hasPrefix(base) else { continue }
      let path = String(full.dropFirst(base.count))
      guard path.hasPrefix(prefix) else { continue }
      entries.append(NoodletEntry(
        path: path, size: values.fileSize ?? 0,
        modified: dates.string(from: values.contentModificationDate ?? .distantPast)))
    }
    return entries.sorted { $0.path < $1.path }
  }
}
