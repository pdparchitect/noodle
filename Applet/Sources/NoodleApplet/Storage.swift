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
    guard let path = call.path else { throw AppletError("A relative data path is required.") }
    let file = try NoodletPath.child(path, in: dataRoot)
    if call.operation == "read" {
      guard FileManager.default.fileExists(atPath: file.path) else { return .null }
      guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 4 * 1_048_576 else {
        throw AppletError("Data file exceeds 4 MiB.")
      }
      return .text(try String(contentsOf: file, encoding: .utf8))
    }
    guard let text = call.text, text.utf8.count <= 4 * 1_048_576 else { throw AppletError("Text must fit in 4 MiB.") }
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: file, atomically: true, encoding: .utf8)
    return .bool(true)
  }
}
