import AppletBridge
import CryptoKit
import Foundation
@_exported import NoodletFormat

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
    let manifestURL = try NoodletPath.child("noodlet.json", in: self.url)
    guard try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 65536 else {
      throw AppletError("Manifest exceeds 64 KiB.")
    }
    do {
      manifest = try JSONDecoder().decode(
        NoodletManifest.self, from: Data(contentsOf: manifestURL))
    } catch { throw AppletError("noodlet.json: \(error.localizedDescription)") }
    try manifest.validate()
    let entry = try NoodletPath.child(manifest.entry, in: self.url)
    guard try entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
      throw AppletError("Missing entry file: \(manifest.entry)")
    }
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
      let target = try NoodletPath.child(name, in: stage)
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
