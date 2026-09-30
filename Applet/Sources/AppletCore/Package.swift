import AppletBridge
import CryptoKit
import Foundation

public struct NoodletManifest: Codable, Sendable, Equatable {
  public var version: Int
  public var title: String
  public var runtime: String
  public var entry: String
  public var summary: String?
  public var symbol: String?
  public var network: Bool
  public var window: NoodletWindowOptions?
  /// Protected resources the user is asked about before the noodlet starts.
  public var permissions: [String]?
  /// Groups the noodlet under one library sidebar category; untagged noodlets appear only in All.
  public var category: String?
  /// The keys a game listens for, shown as a controller to people watching on a phone.
  public var controls: Gamepad?
  public static let knownCategories = [
    "games", "productivity", "utilities", "developer", "data",
    "creativity", "media", "writing", "learning", "lifestyle",
  ]
  public static let knownPermissions = ["microphone", "camera", "speech-recognition", "screen-capture"]
  public init(
    title: String, runtime: String = "html", entry: String = "index.html",
    summary: String? = nil, symbol: String? = nil, network: Bool = false
  ) {
    version = 1
    self.title = title
    self.runtime = runtime
    self.entry = entry
    self.summary = summary
    self.symbol = symbol
    self.network = network
  }
  enum CodingKeys: String, CodingKey {
    case version, title, runtime, entry, summary, symbol, network, window, permissions, category, controls
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
    title = try c.decode(String.self, forKey: .title)
    runtime = try c.decode(String.self, forKey: .runtime)
    entry = try c.decode(String.self, forKey: .entry)
    summary = try c.decodeIfPresent(String.self, forKey: .summary)
    symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
    network = try c.decodeIfPresent(Bool.self, forKey: .network) ?? false
    window = try c.decodeIfPresent(NoodletWindowOptions.self, forKey: .window)
    permissions = try c.decodeIfPresent([String].self, forKey: .permissions)
    category = try c.decodeIfPresent(String.self, forKey: .category)
    controls = try c.decodeIfPresent(Gamepad.self, forKey: .controls)
  }
  public func validate() throws {
    try window?.validate()
    do { try controls?.validate() } catch let error as Gamepad.Invalid { throw AppletError(error.message) }
    for permission in permissions ?? [] where !Self.knownPermissions.contains(permission) {
      throw AppletError("Unknown permission \(permission.prefix(40)). Use \(Self.knownPermissions.joined(separator: ", ")).")
    }
    if let category, !Self.knownCategories.contains(category) {
      throw AppletError("Unknown category \(category.prefix(40)). Use \(Self.knownCategories.joined(separator: ", ")).")
    }
    guard version == 1 else { throw AppletError("Unsupported noodlet version \(version).") }
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 200
    else { throw AppletError("A noodlet needs a title of 1–200 characters.") }
    guard runtime == "html" else { throw AppletError("Runtime must be html.") }
    try AppletRequest.validateRelativePath(entry)
    guard entry.hasSuffix(".html") else { throw AppletError("The entry must be an .html file.") }
  }
}

public struct NoodletPackage: Sendable {
  public let url: URL
  public let manifest: NoodletManifest
  public var key: String { Self.digest(Data(url.path.utf8)) }
  public static func digest(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
  static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
  public init(url: URL, build: AppletBuildIdentity = .current) throws {
    self.url = url.resolvingSymlinksInPath().standardizedFileURL
    guard AppletBuildIdentity.document(self.url) == build,
      try self.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    else {
      throw AppletError("Open a .\(build.fileExtension) document package.")
    }
    let manifestURL = try Self.child("noodlet.json", in: self.url)
    guard try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 65536 else {
      throw AppletError("Manifest exceeds 64 KiB.")
    }
    do {
      manifest = try JSONDecoder().decode(
        NoodletManifest.self, from: Data(contentsOf: manifestURL))
    } catch { throw AppletError("noodlet.json: \(error.localizedDescription)") }
    try manifest.validate()
    let entry = try Self.child(manifest.entry, in: self.url)
    guard try entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
      throw AppletError("Missing entry file: \(manifest.entry)")
    }
  }
  public static func child(_ relative: String, in root: URL) throws -> URL {
    try AppletRequest.validateRelativePath(relative)
    var current = root
    for component in relative.split(separator: "/") {
      current.appendPathComponent(String(component))
      if let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]),
        values.isSymbolicLink == true
      {
        throw AppletError("Symlinks are not allowed inside noodlets: \(relative)")
      }
    }
    return current
  }
  /// The package's files, relative to it and sorted. Hidden files and folders, such as
  /// `.git`, and links are not part of a noodlet.
  public func names() throws -> [String] {
    guard
      let iterator = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
    else { throw AppletError("Cannot read package.") }
    var names: [String] = []
    for case let file as URL in iterator
    where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
      let path = file.standardizedFileURL.path
      guard path.hasPrefix(url.path + "/") else { continue }
      names.append(String(path.dropFirst(url.path.count + 1)))
    }
    return names.sorted()
  }
  public var revision: String {
    guard let names = try? names() else { return "unreadable" }
    var hash = SHA256()
    for name in names {
      guard let handle = try? FileHandle(forReadingFrom: url.appendingPathComponent(name))
      else { return "unreadable" }
      defer { try? handle.close() }
      var file = SHA256()
      while let chunk = try? handle.read(upToCount: 1_048_576), !chunk.isEmpty { file.update(data: chunk) }
      hash.update(data: Data(name.utf8) + Data([0]) + Data(Self.hex(file.finalize()).utf8))
    }
    return Self.hex(hash.finalize())
  }
  public static func install(_ files: [String: Data], to destination: URL, build: AppletBuildIdentity = .current, replaceExisting: Bool = true) throws -> Self {
    guard destination.pathExtension == build.fileExtension else {
      throw AppletError("Use a .\(build.fileExtension) destination.")
    }
    var request = AppletRequest(.validate)
    request.files = files
    try request.validate()
    let fm = FileManager.default
    let parent = destination.deletingLastPathComponent()
    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
    let stage = parent.appendingPathComponent(".\(UUID().uuidString).\(build.fileExtension)")
    try fm.createDirectory(at: stage, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: stage) }
    for (name, data) in files {
      let target = try child(name, in: stage)
      try fm.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: target, options: .atomic)
    }
    _ = try Self(url: stage, build: build)
    if fm.fileExists(atPath: destination.path) {
      guard replaceExisting else { throw AppletError("The destination already exists.") }
      _ = try fm.replaceItemAt(destination, withItemAt: stage)
    } else {
      try fm.moveItem(at: stage, to: destination)
    }
    return try Self(url: destination, build: build)
  }
}
