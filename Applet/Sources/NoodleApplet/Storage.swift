import AppletCore
import Foundation
import WebKit

/// What each noodlet has saved: its data directory and its WebKit store.
@MainActor enum AppletStorage {
  /// Bytes saved per noodlet. `stores` are its website data stores and `websiteData` the
  /// folder WebKit keeps them in; only the page's own data counts, not WebKit's bookkeeping.
  nonisolated static func sizes(root: URL, stores: [String: [UUID]] = [:], websiteData: URL? = nil) -> [String: Int] {
    let data = root.appendingPathComponent("Data")
    var sizes: [String: Int] = [:]
    for key in (try? FileManager.default.contentsOfDirectory(atPath: data.path)) ?? [] {
      sizes[key] = bytes(in: data.appendingPathComponent(key))
    }
    guard let websiteData else { return sizes }
    for (key, ids) in stores {
      for id in ids {
        let store = websiteData.appendingPathComponent(id.uuidString.lowercased())
        // Every origin's folder holds a salt even before the page saves anything.
        let saved = bytes(in: store.appendingPathComponent("Origins")) { $0.lastPathComponent != "salt" }
          + bytes(in: store.appendingPathComponent("Cookies"))
        if saved > 0 { sizes[key, default: 0] += saved }
      }
    }
    return sizes
  }
  nonisolated private static func bytes(in folder: URL, counting: (URL) -> Bool = { _ in true }) -> Int {
    let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
    var total = 0
    while let file = files?.nextObject() as? URL {
      guard counting(file) else { continue }
      total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
    return total
  }
  /// The website data stores each noodlet has used, as launch records them.
  static func stores(defaults: UserDefaults) -> [String: [UUID]] {
    var stores: [String: [UUID]] = [:]
    for (name, value) in defaults.dictionaryRepresentation() where name.hasPrefix("store.") {
      guard let id = (value as? String).flatMap(UUID.init(uuidString:)) else { continue }
      let key = name.dropFirst("store.".count).split(separator: ".").dropLast().joined(separator: ".")
      stores[key, default: []].append(id)
    }
    return stores
  }
  /// Where WebKit keeps identified stores: a sandboxed app's container has no bundle folder.
  nonisolated static var websiteData: URL? {
    guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
    else { return nil }
    let webKit = library.appendingPathComponent("WebKit")
    let candidates = [nil, Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName].map {
      ($0.map { webKit.appendingPathComponent($0) } ?? webKit).appendingPathComponent("WebsiteDataStore")
    }
    return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
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

/// The last measured sizes, kept so Settings shows them at once while it measures again.
@MainActor final class AppletStorageUsage: ObservableObject {
  static let shared = AppletStorageUsage()
  @Published private(set) var sizes: [String: Int]?
  private var generation = 0

  /// Measures off the main thread; a large library takes long to walk. Noodlets with nothing
  /// saved are left out.
  @discardableResult func refresh(
    root: URL, defaults: UserDefaults = .standard, websiteData: URL? = AppletStorage.websiteData
  ) -> Task<Void, Never> {
    generation += 1
    let current = generation
    let stores = AppletStorage.stores(defaults: defaults)
    return Task {
      let sizes = await Task.detached(priority: .utility) {
        let sizes = AppletStorage.sizes(root: root, stores: stores, websiteData: websiteData)
        // Without WebKit's folder, website data cannot be measured, so its noodlets stay listed.
        let unmeasured = websiteData == nil ? stores.mapValues { _ in 0 } : [:]
        return sizes.merging(unmeasured) { size, _ in size }.filter { $0.value > 0 || unmeasured[$0.key] != nil }
      }.value
      if current == generation { self.sizes = sizes }
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
