import Foundation
import WebKit

/// What each noodlet has saved: its data directory and, for HTML, its WebKit store.
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
    for scope in ["user", "test"] {
      let name = "store.\(key).\(scope)"
      if let id = defaults.string(forKey: name).flatMap(UUID.init(uuidString:)) {
        try? await WKWebsiteDataStore.remove(forIdentifier: id)
      }
      defaults.removeObject(forKey: name)
    }
  }
}
