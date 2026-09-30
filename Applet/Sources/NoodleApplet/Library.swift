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

/// Where Noodle or Noodle Hub keeps its bots, each bot's own work in `<bot id>/workspace`.
/// Applet finds the noodlets bots make there itself and uses them where they are.
struct BotFolder: Equatable {
  let url: URL
  /// Noodle Hub's bots, whose noodlets are listed under Hub, apart from this Mac's own.
  let isHub: Bool

  /// Noodle's and Noodle Hub's, in their own containers, for this environment.
  static var system: [BotFolder] {
    // Applet is sandboxed too, so its own home is its container, not the user's.
    let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
    let identity = AppletBuildIdentity.current
    return [(identity.noodleID, false), (identity.hubID, true)].map { app, hub in
      // Both keep their bots in Application Support/Noodle/Agents.
      BotFolder(url: URL(fileURLWithPath: home).appendingPathComponent(
        "Library/Containers/\(app)/Data/Library/Application Support/Noodle/Agents", isDirectory: true), isHub: hub)
    }
  }
}

/// Someone on Noodle Hub, as their bot's agent.json names them.
struct HubPerson: Hashable, Identifiable, Decodable {
  let id: UUID
  let name: String
}

@MainActor final class AppletLibrary: ObservableObject {
  let root: URL
  let documents: URL
  let botFolders: [BotFolder]
  @Published var entries: [LibraryEntry] = []
  @Published var error: String?
  @Published var recent: [String]
  @Published var pinned: [String]
  /// Kept in the library but listed only under Hidden, and Running while up: never in All, Recent, Pinned or the menu bar.
  @Published var hidden: [String]
  /// Made or opened by Noodle Hub's bots; listed only under Hub, apart from this Mac's own.
  @Published var hub: [String]
  /// Whose bot made each of Noodle Hub's noodlets, where the Hub names them.
  @Published private(set) var hubOwners: [String: HubPerson] = [:]
  private let defaults: UserDefaults
  private struct Registration {
    let url: URL
    let bookmark: Data
    let scoped: Bool
  }
  private var registrations: [Registration] = []
  private var timer: Timer?
  private var refreshing = false
  private var links: NoodletRegistry?
  /// Where noodlets keep their secrets, whichever device their page runs on.
  let secrets: AppletSecrets

  init(
    root: URL? = nil, defaults: UserDefaults = .standard, installExamples: Bool = true,
    watchChanges: Bool = true, botFolders: [BotFolder]? = nil, secrets: AppletSecrets = .shared
  ) {
    self.defaults = defaults
    self.secrets = secrets
    // A library kept elsewhere, as in a test, finds only the bots it is given.
    self.botFolders = botFolders ?? (root == nil ? BotFolder.system : [])
    self.root =
      root
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("NoodleApplet")
    documents = self.root.appendingPathComponent("Noodlets")
    recent = defaults.stringArray(forKey: "recent") ?? []
    pinned = defaults.stringArray(forKey: "pinned") ?? []
    hidden = defaults.stringArray(forKey: "hidden") ?? []
    hub = defaults.stringArray(forKey: "hub") ?? []
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
    removeCopies(secrets: secrets)
    removeSwiftBuilds(secrets: secrets)
    scan()
    if watchChanges {
      timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
        Task { @MainActor in await self?.refresh() }
      }
    }
  }
  /// The bot whose workspace holds `url`, by the name of its folder; nil for anything else.
  func owner(of url: URL) -> String? { bot(holding: url)?.owner }
  /// Whether `url` is in the workspace of one of Noodle Hub's bots.
  func isHub(_ url: URL) -> Bool { bot(holding: url)?.folder.isHub == true }
  private func bot(holding url: URL) -> (folder: BotFolder, owner: String)? {
    let parts = Self.canonical(url).pathComponents
    for folder in botFolders {
      let base = Self.canonical(folder.url).pathComponents
      guard parts.count > base.count + 2, Array(parts.prefix(base.count)) == base,
        parts[base.count + 1] == "workspace"
      else { continue }
      return (folder, parts[base.count])
    }
    return nil
  }
  /// The lists of noodlet keys the library keeps, with where each is saved.
  private static let lists: [(ReferenceWritableKeyPath<AppletLibrary, [String]>, String)] = [
    (\.recent, "recent"), (\.pinned, "pinned"), (\.hidden, "hidden"), (\.hub, "hub"),
  ]
  // TODO(Applet 0.20.0): remove with installedOrbit, its call in init,
  // LibraryTests.testWhatSwiftNoodletsLeftGoesAndTheirDataStays and
  // LibraryTests.testTheSwiftExampleGoesUnlessItWasChanged. Milestone: Applet 0.19.0.
  /// The Orbital playground example as Applet put it in the library, by its Orbit.swift.
  static var installedOrbit = "ed26526b98a23950c3ffbf3f58d91f5b8e6d2ca9edb3840fe151babe17b089d9"
  /// Noodlets written in Swift were built under Builds and ran with a private home under Homes.
  /// The Swift example goes too, with what Applet kept for it, unless the person changed it.
  private func removeSwiftBuilds(secrets: AppletSecrets) {
    for folder in ["Builds", "Homes"] { try? FileManager.default.removeItem(at: root.appendingPathComponent(folder)) }
    let orbit = Self.canonical(documents.appendingPathComponent("Orbit.\(AppletBuildIdentity.current.fileExtension)"))
    guard let source = try? Data(contentsOf: orbit.appendingPathComponent("Orbit.swift")),
      NoodletPackage.digest(source) == Self.installedOrbit,
      (try? FileManager.default.removeItem(at: orbit)) != nil
    else { return }
    forget(NoodletPackage.digest(Data(orbit.path.utf8)), secrets: secrets)
    for (list, name) in Self.lists { defaults.set(self[keyPath: list], forKey: name) }
  }
  // TODO(Applet 0.13.0): remove with its call in init, LibraryTests.testCopiesFromBeforeGoAndWhatTheyKeptFollowsTheOriginal
  // and LibraryTests.testACopyWhoseOriginalCannotBeReadIsKeptForLater. Milestone: Applet 0.12.0.
  /// Applet used to keep a copy of each noodlet a bot sent, under Imports. The copies go. What
  /// was kept for one, its link, saved data, permissions, secrets and place in lists, follows the
  /// bot's own noodlet while that is still there, and goes with the copy when it is not.
  private func removeCopies(secrets: AppletSecrets) {
    let imports = documents.appendingPathComponent("Imports", isDirectory: true)
    let origins = defaults.dictionary(forKey: "sourceOrigins") as? [String: String] ?? [:]
    guard !origins.isEmpty || FileManager.default.fileExists(atPath: imports.path) else { return }
    // Copies whose original is there but cannot be read now, as when macOS keeps Applet out of a
    // bot's folder, wait for a later launch rather than be taken for ones whose original is gone.
    var waiting: [String: String] = [:]
    for (origin, copyPath) in origins {
      guard let copy = try? NoodletPackage(url: URL(fileURLWithPath: copyPath)) else { continue }
      let sourceURL = URL(fileURLWithPath: String(origin.split(separator: "\0", maxSplits: 1).last ?? ""))
      guard let source = try? NoodletPackage(url: sourceURL) else {
        if Self.missing(sourceURL) { forget(copy.key, secrets: secrets) } else { waiting[origin] = copyPath }
        continue
      }
      try? links?.move(copy.url, to: source.url)
      let (old, new) = (copy.key, source.key)
      for folder in ["Data", "Homes"] {
        let from = root.appendingPathComponent("\(folder)/\(old)"), to = root.appendingPathComponent("\(folder)/\(new)")
        if !FileManager.default.fileExists(atPath: to.path) { try? FileManager.default.moveItem(at: from, to: to) }
      }
      let thumbnails = root.appendingPathComponent("Thumbnails")
      try? FileManager.default.moveItem(
        at: thumbnails.appendingPathComponent("\(old).png"), to: thumbnails.appendingPathComponent("\(new).png"))
      for name in ["store.%@.user", "store.%@.test", "permissions.%@"] {
        guard let value = defaults.object(forKey: String(format: name, old)) else { continue }
        if defaults.object(forKey: String(format: name, new)) == nil { defaults.set(value, forKey: String(format: name, new)) }
        defaults.removeObject(forKey: String(format: name, old))
      }
      for scope in ["user", "test"] {
        let kept = (try? secrets.storage.load("\(old).\(scope)")) ?? [:]
        if !kept.isEmpty, ((try? secrets.storage.load("\(new).\(scope)")) ?? [:]).isEmpty {
          try? secrets.storage.save(kept, account: "\(new).\(scope)")
        }
        try? secrets.storage.save([:], account: "\(old).\(scope)")
      }
      for (list, _) in Self.lists {
        var seen = Set<String>()
        self[keyPath: list] = self[keyPath: list].map { $0 == old ? new : $0 }.filter { seen.insert($0).inserted }
      }
    }
    for (list, name) in Self.lists { defaults.set(self[keyPath: list], forKey: name) }
    guard waiting.isEmpty else {
      let kept = Set(waiting.values.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
      for (_, copyPath) in origins where !kept.contains(URL(fileURLWithPath: copyPath).standardizedFileURL.path) {
        try? FileManager.default.removeItem(atPath: copyPath)
      }
      defaults.set(waiting, forKey: "sourceOrigins")
      return
    }
    try? FileManager.default.removeItem(at: imports)
    defaults.removeObject(forKey: "sourceOrigins")
    defaults.removeObject(forKey: "packageOwners")
  }
  /// Deletes what Applet kept for a noodlet that no longer exists, as trashing it does.
  private func forget(_ key: String, secrets: AppletSecrets) {
    for (list, _) in Self.lists { self[keyPath: list].removeAll { $0 == key } }
    Task { await AppletStorage.remove(key, root: root, defaults: defaults) }
    AppletPermissions.revoke(packageKey: key, defaults: defaults)
    for scope in ["user", "test"] { try? secrets.storage.save([:], account: "\(key).\(scope)") }
    try? FileManager.default.removeItem(at: root.appendingPathComponent("Thumbnails/\(key).png"))
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
    let places = forget()
    apply(Self.discover(in: places, botFolders: botFolders.map(\.url), thumbnails: root.appendingPathComponent("Thumbnails", isDirectory: true)))
  }
  /// What the watch timer runs. Walking bots' workspaces takes a tenth of a second or more, and
  /// recordings and live views capture on the main thread, so the walk happens off it.
  func refresh() async {
    guard !refreshing else { return }
    refreshing = true
    defer { refreshing = false }
    let places = forget(), folders = botFolders.map(\.url)
    let thumbnails = root.appendingPathComponent("Thumbnails", isDirectory: true)
    apply(await Task.detached { Self.discover(in: places, botFolders: folders, thumbnails: thumbnails) }.value)
  }
  /// Drops what was deleted and returns where to look for noodlets.
  private func forget() -> [URL] {
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
      hub.removeAll { deleted.contains($0) }
      defaults.set(recent, forKey: "recent")
      defaults.set(pinned, forKey: "pinned")
      defaults.set(hidden, forKey: "hidden")
      defaults.set(hub, forKey: "hub")
    }
    return [documents] + registrations.map(\.url)
  }
  /// Every noodlet in `places` and in the workspaces of the bots in `botFolders`.
  nonisolated static func discover(in places: [URL], botFolders: [URL], thumbnails: URL) -> [String: LibraryEntry] {
    let workspaces = botFolders.flatMap { folder in
      ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
        .map { $0.appendingPathComponent("workspace", isDirectory: true) }
        .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    var found: [String: LibraryEntry] = [:]
    for directory in places + workspaces {
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
    return found
  }
  private func apply(_ found: [String: LibraryEntry]) {
    let next = found.values.sorted {
      let order = $0.title.localizedStandardCompare($1.title)
      return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
    }
    if entries != next { entries = next }
    for entry in entries where isHub(entry.package.url) { markHub(entry.id) }
    // Read once for each bot: agent.json holds its picture too.
    var people: [URL: HubPerson?] = [:]
    let owners = entries.reduce(into: [String: HubPerson]()) { owners, entry in
      guard let bot = bot(holding: entry.package.url), bot.folder.isHub else { return }
      let folder = bot.folder.url.appendingPathComponent(bot.owner)
      if people[folder] == nil { people[folder] = .some(Self.person(owning: folder)) }
      owners[entry.id] = people[folder] ?? nil
    }
    if hubOwners != owners { hubOwners = owners }
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
      recent.filter { !pinned.contains($0) && !hidden.contains($0) && !hub.contains($0) }
        .compactMap { key in entries.first { $0.id == key } }.prefix(8))
  }
  /// Categories holding at least one of this Mac's own noodlets that is not hidden, in the
  /// fixed category order.
  var categories: [String] {
    let used = Set(entries.filter { !hidden.contains($0.id) && !hub.contains($0.id) }.compactMap(\.package.manifest.category))
    return NoodletManifest.knownCategories.filter(used.contains)
  }
  /// People with noodlets under Hub that are not hidden, by name.
  var hubPeople: [HubPerson] {
    let people = Set(hubOwners.filter { !hidden.contains($0.key) }.values)
    return people.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
  private static func person(owning bot: URL) -> HubPerson? {
    struct Configuration: Decodable { let owner: HubPerson? }
    guard let data = try? Data(contentsOf: bot.appendingPathComponent("agent.json")) else { return nil }
    return (try? JSONDecoder().decode(Configuration.self, from: data))?.owner
  }
  func markHub(_ key: String) {
    guard !hub.contains(key) else { return }
    hub.append(key)
    defaults.set(hub, forKey: "hub")
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
