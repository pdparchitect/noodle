import AppKit
import AppletCore
import AppletBridge
import Foundation
import UniformTypeIdentifiers

struct LibraryEntry: Identifiable, Equatable {
  let id: String
  let package: NoodletPackage
  var title: String { package.manifest.title }
  private let previews: [PreviewStamp]

  init(package: NoodletPackage, thumbnails: URL) {
    self.package = package
    id = package.key
    previews = [thumbnails.appendingPathComponent("\(id).png"),
                package.url.appendingPathComponent("preview.png")].map(PreviewStamp.init)
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.package.manifest == rhs.package.manifest && lhs.previews == rhs.previews
  }

  /// Capture metadata now; comparing live computed revisions would reread every
  /// package file and would compare both entries against the same current bytes.
  private struct PreviewStamp: Equatable {
    let modified: Date?
    let size: Int?
    init(_ url: URL) {
      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
      modified = values?.contentModificationDate
      size = values?.fileSize
    }
  }
}

@MainActor final class AppletLibrary: ObservableObject {
  let root: URL
  let documents: URL
  @Published var entries: [LibraryEntry] = []
  @Published var error: String?
  @Published var recent: [String]
  @Published var pinned: [String]
  /// Kept in the library but listed only under Hidden: never in All, Recent, Pinned or the menu bar.
  @Published var hidden: [String]
  private let defaults: UserDefaults
  private struct Registration {
    let url: URL
    let bookmark: Data
    let scoped: Bool
  }
  private var registrations: [Registration] = []
  private var timer: Timer?
  private var links: NoodletRegistry?

  init(
    root: URL? = nil, defaults: UserDefaults = .standard, installExamples: Bool = true,
    watchChanges: Bool = true
  ) {
    self.defaults = defaults
    self.root =
      root
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("NoodleApplet")
    documents = self.root.appendingPathComponent("Noodlets")
    recent = defaults.stringArray(forKey: "recent") ?? []
    pinned = defaults.stringArray(forKey: "pinned") ?? []
    hidden = defaults.stringArray(forKey: "hidden") ?? []
    do {
      try FileManager.default.createDirectory(
        at: documents, withIntermediateDirectories: true)
      links = try NoodletRegistry(file: self.root.appendingPathComponent("NoodletLinks.json"))
      if installExamples, !defaults.bool(forKey: "examplesInstalled"),
        let source = AppletResources.bundle.url(
          forResource: "Resources", withExtension: nil)?.appendingPathComponent(
            "Examples")
      {
        for item
          in (try? FileManager.default.contentsOfDirectory(
            at: source, includingPropertiesForKeys: nil)) ?? []
        where item.pathExtension == AppletBuildIdentity.current.fileExtension {
          let target = documents.appendingPathComponent(item.lastPathComponent)
          if !FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.copyItem(at: item, to: target)
          }
        }
        defaults.set(true, forKey: "examplesInstalled")
      }
      if installExamples,
        let source = AppletResources.bundle.url(forResource: "Resources", withExtension: nil)?
          .appendingPathComponent("Examples/Focus.\(AppletBuildIdentity.current.fileExtension)"),
        let current = try? NoodletPackage(url: documents.appendingPathComponent("Focus.\(AppletBuildIdentity.current.fileExtension)")),
        ["fe2f24327c07f9f73b37a4c5d1e8d0e72a87f69d63a43b2d9c14bf965565cf20", "eefb19b06f5a496f30a956a9f1a57dbf30c0dd2ce2c5d4f2176d8f38b6110db2"].contains(current.revision)
      {
        // Upgrade only the unmodified bundled example; keep authored changes and saved data.
        _ = try NoodletPackage.install(NoodletPackage(url: source).files(), to: current.url)
      }
    } catch { self.error = error.localizedDescription }
    // Restore each opened package independently. A missing or damaged
    // bookmark must never prevent other creations from appearing.
    for data in defaults.array(forKey: "libraryBookmarks") as? [Data] ?? [] {
      do {
        var stale = false
        let url = try URL(
          resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
          bookmarkDataIsStale: &stale)
        let active = url.startAccessingSecurityScopedResource()
        if Self.missing(url)
          || registrations.contains(where: {
            Self.canonical($0.url) == Self.canonical(url)
          })
        {
          if active { url.stopAccessingSecurityScopedResource() }
          continue
        }
        let refreshed =
          stale
          ? try? url.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil,
            relativeTo: nil) : nil
        registrations.append(
          Registration(url: url, bookmark: refreshed ?? data, scoped: active))
      } catch { continue }
    }
    persistRegistrations()
    scan()
    if watchChanges {
      timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.scan() }
      }
    }
  }
  private static func canonical(_ url: URL) -> URL {
    url.resolvingSymlinksInPath().standardizedFileURL
  }
  private static func missing(_ url: URL) -> Bool {
    do { return !(try url.checkResourceIsReachable()) } catch {
      let error = error as NSError
      return
        (error.domain == NSCocoaErrorDomain
        && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code))
        || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }
  }
  private func persistRegistrations() {
    let bookmarks = registrations.map(\.bookmark)
    if bookmarks != defaults.array(forKey: "libraryBookmarks") as? [Data] {
      defaults.set(bookmarks, forKey: "libraryBookmarks")
    }
  }
  func scan() {
    let deleted = Set(entries.filter { Self.missing($0.package.url) }.map(\.id))
    registrations.removeAll { registration in
      guard Self.missing(registration.url) else { return false }
      if registration.scoped { registration.url.stopAccessingSecurityScopedResource() }
      return true
    }
    persistRegistrations()
    if !deleted.isEmpty {
      recent.removeAll { deleted.contains($0) }
      pinned.removeAll { deleted.contains($0) }
      hidden.removeAll { deleted.contains($0) }
      defaults.set(recent, forKey: "recent")
      defaults.set(pinned, forKey: "pinned")
      defaults.set(hidden, forKey: "hidden")
    }
    var found: [String: LibraryEntry] = [:]
    let thumbnails = root.appendingPathComponent("Thumbnails", isDirectory: true)
    for directory in [documents] + registrations.map(\.url) {
      if AppletBuildIdentity.document(directory) == .current {
        if let package = try? NoodletPackage(url: directory) {
          let entry = LibraryEntry(package: package, thumbnails: thumbnails)
          found[entry.id] = entry
        }
        continue
      }
      guard
        let walker = FileManager.default.enumerator(
          at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey],
          options: [.skipsHiddenFiles])
      else { continue }
      var count = 0
      for case let url as URL in walker {
        count += 1
        if count > 10000 { break }
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
          walker.skipDescendants()
          continue
        }
        if AppletBuildIdentity.document(url) == .current {
          walker.skipDescendants()
          if let package = try? NoodletPackage(url: url) {
            let entry = LibraryEntry(package: package, thumbnails: thumbnails)
            found[entry.id] = entry
          }
        } else if walker.level > 4 {
          walker.skipDescendants()
        }
      }
    }
    let next = found.values.sorted {
      let order = $0.title.localizedStandardCompare($1.title)
      return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
    }
    if entries != next { entries = next }
    for entry in entries {
      do { _ = try linkID(for: entry.package) } catch { self.error = error.localizedDescription }
    }
  }
  func linkID(for package: NoodletPackage) throws -> UUID {
    guard let links else { throw NSError(domain: "NoodletRegistry", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Noodlet link registry is unavailable."]) }
    return try links.id(for: package.url)
  }
  func package(for id: UUID) throws -> NoodletPackage {
    guard let url = links?.resolve(id) else { throw NSError(domain: "NoodletRegistry", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "This noodlet is no longer available."]) }
    let package = try NoodletPackage(url: url)
    // A bookmark can follow a moved file before the library's next scan.
    if !entries.contains(where: { $0.package.url == package.url }) { try grant(url) }
    return package
  }
  func remember(_ package: NoodletPackage) {
    recent.removeAll { $0 == package.key }
    recent.insert(package.key, at: 0)
    recent = Array(recent.prefix(30))
    defaults.set(recent, forKey: "recent")
    scan()
  }
  /// Pinned noodlets for the menu bar, in pin order.
  var menuPinned: [LibraryEntry] {
    pinned.filter { !hidden.contains($0) }.compactMap { key in entries.first { $0.id == key } }
  }
  /// The most recent noodlets for the menu bar that are not already pinned there.
  var menuRecent: [LibraryEntry] {
    Array(
      recent.filter { !pinned.contains($0) && !hidden.contains($0) }
        .compactMap { key in entries.first { $0.id == key } }.prefix(8))
  }
  /// Categories holding at least one noodlet that is not hidden, in the fixed category order.
  var categories: [String] {
    let used = Set(entries.filter { !hidden.contains($0.id) }.compactMap(\.package.manifest.category))
    return NoodletManifest.knownCategories.filter(used.contains)
  }
  /// Hides a noodlet, or shows a hidden one again. Its pin is kept for when it is shown.
  func hide(_ key: String) {
    if hidden.contains(key) { hidden.removeAll { $0 == key } } else { hidden.append(key) }
    defaults.set(hidden, forKey: "hidden")
  }
  /// Moves a noodlet to the Trash, then deletes what it saved, its secrets, permissions and thumbnail.
  /// Nothing is deleted when the move fails.
  func trash(
    _ package: NoodletPackage, secrets: AppletSecrets = .shared,
    moveToTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
  ) async throws {
    try moveToTrash(package.url)
    scan()
    await AppletStorage.remove(package.key, root: root, defaults: defaults)
    AppletPermissions.revoke(packageKey: package.key, defaults: defaults)
    for scope in ["user", "test"] { try? secrets.storage.save([:], account: "\(package.key).\(scope)") }
    try? FileManager.default.removeItem(at: root.appendingPathComponent("Thumbnails/\(package.key).png"))
  }
  func pin(_ key: String) {
    if pinned.contains(key) { pinned.removeAll { $0 == key } } else { pinned.append(key) }
    defaults.set(pinned, forKey: "pinned")
  }
  func grant(_ url: URL) throws {
    let active = url.startAccessingSecurityScopedResource()
    var retained = false
    defer { if active && !retained { url.stopAccessingSecurityScopedResource() } }
    let package = try NoodletPackage(url: url)
    if !registrations.contains(where: { Self.canonical($0.url) == package.url }) {
      let bookmark = try url.bookmarkData(
        options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
      registrations.append(Registration(url: url, bookmark: bookmark, scoped: active))
      retained = true
      persistRegistrations()
    }
    scan()
  }
  deinit {
    timer?.invalidate()
    for registration in registrations where registration.scoped {
      registration.url.stopAccessingSecurityScopedResource()
    }
  }
  func choosePackage(open: @escaping (NoodletPackage) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.treatsFilePackagesAsDirectories = false
    panel.allowedContentTypes = [UTType(AppletBuildIdentity.current.contentType) ?? .package]
    panel.prompt = "Open Noodlet"
    panel.begin { [weak self] result in
      Task { @MainActor in
        guard result == .OK, let url = panel.url else { return }
        do {
          try self?.grant(url)
          open(try NoodletPackage(url: url))
        } catch { self?.error = error.localizedDescription }
      }
    }
  }
}
