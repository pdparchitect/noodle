import Foundation

public enum PreviewCache {
  public static func file(for package: URL, bundle: Bundle = .main) -> URL? {
    guard let group = bundle.object(forInfoDictionaryKey: "NoodleAppletGroup") as? String,
      let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    else { return nil }
    let key = NoodletPackage.digest(
      Data(package.resolvingSymlinksInPath().standardizedFileURL.path.utf8))
    return root.appendingPathComponent("Previews/\(key).png")
  }
  public static func save(_ data: Data, for package: URL) throws {
    guard let file = file(for: package) else { return }
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: file, options: .atomic)
  }
}
