import AppKit
import AppletCore
import Foundation
import UniformTypeIdentifiers

struct LibraryEntry: Identifiable {
  var id: String { package.key }
  let package: NoodletPackage
  var title: String { package.manifest.title }
}

@MainActor final class AppletLibrary: ObservableObject {
  let root: URL
  let documents: URL
  @Published var entries: [LibraryEntry] = []
  @Published var error: String?
  @Published var recent: [String]
  @Published var pinned: [String]
  private let defaults: UserDefaults
  private struct Registration {
    let url: URL
    let bookmark: Data
    let scoped: Bool
  }
  private var registrations: [Registration] = []
  private var timer: Timer?

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
    do {
      try FileManager.default.createDirectory(
        at: documents, withIntermediateDirectories: true)
      if installExamples, !defaults.bool(forKey: "examplesInstalled"),
        let source = AppletResources.bundle.url(
          forResource: "Resources", withExtension: nil)?.appendingPathComponent(
            "Examples")
      {
        for item
          in (try? FileManager.default.contentsOfDirectory(
            at: source, includingPropertiesForKeys: nil)) ?? []
        where item.pathExtension == "noodlet" {
          let target = documents.appendingPathComponent(item.lastPathComponent)
          if !FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.copyItem(at: item, to: target)
          }
        }
        defaults.set(true, forKey: "examplesInstalled")
      }
      if installExamples,
        let source = AppletResources.bundle.url(forResource: "Resources", withExtension: nil)?
          .appendingPathComponent("Examples/Focus.noodlet"),
        let current = try? NoodletPackage(url: documents.appendingPathComponent("Focus.noodlet")),
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
      defaults.set(recent, forKey: "recent")
      defaults.set(pinned, forKey: "pinned")
    }
    var found: [String: LibraryEntry] = [:]
    for directory in [documents] + registrations.map(\.url) {
      if directory.pathExtension == "noodlet" {
        if let package = try? NoodletPackage(url: directory) {
          found[package.key] = LibraryEntry(package: package)
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
        if url.pathExtension == "noodlet" {
          walker.skipDescendants()
          if let package = try? NoodletPackage(url: url) {
            found[package.key] = LibraryEntry(package: package)
          }
        } else if walker.level > 4 {
          walker.skipDescendants()
        }
      }
    }
    entries = found.values.sorted {
      $0.title.localizedStandardCompare($1.title) == .orderedAscending
    }
  }
  func remember(_ package: NoodletPackage) {
    recent.removeAll { $0 == package.key }
    recent.insert(package.key, at: 0)
    recent = Array(recent.prefix(30))
    defaults.set(recent, forKey: "recent")
    scan()
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
    panel.allowedContentTypes = [UTType(filenameExtension: "noodlet") ?? .package]
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
