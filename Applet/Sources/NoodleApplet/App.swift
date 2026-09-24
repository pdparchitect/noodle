import AppKit
import AppletBridge
import AppletCore
import NoodleLaunchChecks
import NoodleWallpaper
import SwiftUI
import NoodleSettingsUI
import OSLog

@main struct NoodleAppletApp: App {
  @NSApplicationDelegateAdaptor(AppletDelegate.self) private var delegate
  @ObservedObject private var visibility = CompanionAppVisibility.shared

  var body: some Scene {
    Window(AppletBuildIdentity.current.appName, id: "library") {
      LibraryView(library: delegate.library, runtime: delegate.runtime, background: delegate.background)
        .companionSettingsAccess()
        .handlesExternalEvents(preferring: [], allowing: [])
        .frame(minWidth: 850, minHeight: 580)
        .preferredColorScheme(.dark)
        .task {
          if LaunchChecks.current.contains(AppletLaunchCheck.updaterUI) {
            do {
              try await AppletUITest.run()
              NSApp.terminate(nil)
            } catch {
              fputs("APPLET UI TEST FAILED: \(error.localizedDescription)\n", stderr)
              exit(1)
            }
          }
        }
    }
    // AppKit distinguishes an app launch from a file/URL launch below.
    .defaultLaunchBehavior(.suppressed)
    .restorationBehavior(.disabled)
    .handlesExternalEvents(matching: [])
    .defaultSize(width: 1080, height: 720)
    .windowToolbarStyle(.unified(showsTitle: false))
    .commands {
      CommandGroup(after: .appSettings) { AppletCheckForUpdatesButton() }
      CommandGroup(replacing: .appInfo) {
        Button("About \(AppletBuildIdentity.current.appName)") {
          NSApp.orderFrontStandardAboutPanel(options: [.applicationName: AppletBuildIdentity.current.appName])
        }
      }
      CommandGroup(replacing: .help) {
        Button("\(AppletBuildIdentity.current.appName) Help") { NSWorkspace.shared.open(AppletLinks.repository) }
      }
      AppletFileCommands(delegate: delegate, runtime: delegate.runtime)
    }
    Settings {
      AppletSettingsView(background: delegate.background, library: delegate.library, runtime: delegate.runtime).preferredColorScheme(.dark)
    }
    .windowResizability(.contentSize)
    .handlesExternalEvents(matching: [])
    MenuBarExtra(isInserted: $visibility.showMenuBar) {
      AppletMenu(library: delegate.library, runtime: delegate.runtime, openLibrary: delegate.reopenLibrary)
    } label: {
      CompanionMenuBarLabel(AppletBuildIdentity.current.appName)
    }
    .handlesExternalEvents(matching: [])
  }
}

enum AppletLinks {
  static let repository = URL(string: "https://github.com/pdparchitect/noodle")!
}

/// Launch arguments that verification runs pass, matched by digest; see Shared/LaunchChecks.
enum AppletLaunchCheck {
  static let updaterUI = "33f8b12621881e80aeaf87bc1d61ef880882e6b5cf0d3a2a1fc3e7ee99b42609"  // --updater-ui-test
  static let rendering = "52ea2badcdd8b0ad5e3cb36f6052f7b70ed61e6923b77abfe07ccde40e3cb2b0"  // --rendering-test
  static let backgroundLaunchUI = "cf13d7cc0216ca2633f6bec3a325fd72f51397f0bfbd6639a35dcf4af8750c02"  // --background-launch-ui-test
  #if NOODLE_DEV_HOOKS
  static let launchCapture = "7de812b196feeb9c1ee78b09d6d8006ad9eea78abeef8e10377234f723754799"  // --launch-check
  #endif
  static var isVerificationRun: Bool {
    [updaterUI, rendering, backgroundLaunchUI].contains(where: LaunchChecks.current.contains)
  }
}

private struct AppletMenu: View {
  @ObservedObject var library: AppletLibrary
  @ObservedObject var runtime: AppletRuntime
  let openLibrary: () -> Void

  var body: some View {
    Button("Open Library", action: openLibrary)
    Divider()
    ForEach(library.menuPinned) { entry in
      Button {
        runtime.open(entry.package)
      } label: {
        Label(entry.title, systemImage: "pin.fill")
      }
    }
    if !library.menuPinned.isEmpty { Divider() }
    ForEach(library.menuRecent) { entry in
      Button(entry.title) { runtime.open(entry.package) }
    }
    Divider()
    CompanionMenuSettingsButton()
    Button("Quit \(AppletBuildIdentity.current.appName)") { NSApp.terminate(nil) }.keyboardShortcut("q")
  }
}

@MainActor final class AppletDelegate: NSObject, NSApplicationDelegate {
  var openLibrary: (() -> Void)? {
    didSet {
      if needsLibrary, openLibrary != nil {
        needsLibrary = false
        DispatchQueue.main.async { [weak self] in self?.reopenLibrary() }
      }
    }
  }
  private var needsLibrary = false
  let library = AppletLibrary()
  lazy var background = AppletBackgroundStore(root: library.root)
  lazy var runtime = AppletRuntime(library: library)
  private var openedExternalItem = false
  private let launchLog = Logger(subsystem: AppletConnection.providerID, category: "Launch")

  func applicationDidBecomeActive(_ notification: Notification) {
    // Quiet agent launches must not display update prompts.
    AppletUpdater.shared.start()
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    WindowFocusGuard.shared.start()
    CompanionAppVisibility.shared.start(permitsDock: !AppletLaunchCheck.isVerificationRun)
    let defaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool == true
    launchLog.notice("Provider launched; default app launch: \(defaultLaunch)")
    #if NOODLE_DEV_HOOKS
    // scripts/verify-launch-hooks.sh refuses a release that carries this marker.
    launchLog.notice("noodle.development-hooks.enabled")
    #endif
    if LaunchChecks.current.contains(AppletLaunchCheck.rendering) {
      Task { @MainActor in
        do {
          try await AppletRenderingTest.run()
          NSApp.terminate(nil)
        } catch {
          fputs("APPLET RENDERING TEST FAILED: \(error.localizedDescription)\n", stderr)
          exit(1)
        }
      }
    } else if LaunchChecks.current.contains(AppletLaunchCheck.backgroundLaunchUI) {
      Task { @MainActor in
        do {
          try await AppletUITest.runBackgroundLaunch()
          NSApp.terminate(nil)
        } catch {
          fputs("APPLET BACKGROUND LAUNCH TEST FAILED: \(error.localizedDescription)\n", stderr)
          exit(1)
        }
      }
    } else if LaunchChecks.current.contains(AppletLaunchCheck.updaterUI) {
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(250))
        reopenLibrary()
      }
    } else {
      runtime.startServer()
      if !CommandLine.arguments.contains("--noodle-background"),
        notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool == true {
        DispatchQueue.main.async { [weak self] in
          guard let self, !self.openedExternalItem else { return }
          self.reopenLibrary()
        }
      }
    }
    if CommandLine.arguments.contains("--noodle-background") { NSApp.hide(nil) }
    #if NOODLE_DEV_HOOKS
    if LaunchChecks.current.contains(AppletLaunchCheck.launchCapture) {
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(2))
        AppletUITest.captureLaunch(isDefault: notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool,
          external: self.openedExternalItem)
      }
    }
    #endif
  }

  func reopenLibrary() {
    launchLog.notice("Opening catalogue")
    if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "library" }) {
      window.makeKeyAndOrderFront(nil)
    } else if let openLibrary {
      openLibrary()
    } else {
      // A launch by URL arrives before the scene provides the window action.
      needsLibrary = true
    }
    NSApp.unhide(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    launchLog.notice("Received app reopen event")
    reopenLibrary()
    return true
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationWillTerminate(_ notification: Notification) { runtime.shutdown() }
  func application(_ application: NSApplication, open urls: [URL]) {
    openedExternalItem = true
    for url in urls {
      // A sandboxed Noodle launch arrives as a URL without --noodle-background.
      // Receiving it is enough: applicationDidFinishLaunching starts the server.
      if url == AppletLaunch.backgroundURL {
        launchLog.notice("Received background provider URL")
        continue
      }
      if url == AppletLaunch.updateCheckURL() {
        launchLog.notice("Received update check URL")
        reopenLibrary()
        AppletUpdater.shared.start()
        AppletUpdater.shared.check()
        continue
      }
      do {
        if NoodletLink.id(in: url) != nil {
          let id = try NoodletLink.requireID(in: url)
          runtime.open(try library.package(for: id))
        } else if url.isFileURL {
          try library.grant(url)
          runtime.open(try NoodletPackage(url: url))
        } else { throw AppletError("Invalid noodlet link.") }
      } catch {
        runtime.error = error.localizedDescription
        NSAlert(error: error).runModal()
      }
    }
  }
}

private enum LibrarySection: String, CaseIterable, Identifiable {
  case all = "All"
  case recent = "Recent"
  case pinned = "Pinned"
  case hidden = "Hidden"
  var id: Self { self }
  var symbol: String {
    switch self {
    case .all: "square.grid.2x2"
    case .recent: "clock"
    case .pinned: "pin"
    case .hidden: "eye.slash"
    }
  }
}

/// A library section, or a category from the noodlets' manifests.
private enum LibraryFilter: Hashable {
  case section(LibrarySection)
  case category(String)
  static let categorySymbols = [
    "games": "gamecontroller", "productivity": "checklist", "utilities": "wrench.and.screwdriver",
    "developer": "chevron.left.forwardslash.chevron.right", "data": "chart.bar",
    "creativity": "paintbrush", "media": "play.rectangle", "writing": "text.alignleft",
    "learning": "graduationcap", "lifestyle": "heart",
  ]
}

private struct LibraryView: View {
  @ObservedObject var library: AppletLibrary
  @ObservedObject var runtime: AppletRuntime
  @ObservedObject var background: AppletBackgroundStore
  @State private var search = ""
  @State private var searching = false
  @State private var searchFocused = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var selection: LibraryFilter? = .section(.all)
  @State private var columnVisibility = NavigationSplitViewVisibility.all
  @State private var trashing: LibraryEntry?
  @AppStorage("AppletSidebarVisible") private var sidebarVisible = true
  @AppStorage("AppletCategoriesExpanded") private var categoriesExpanded = true

  private var section: LibrarySection? {
    if case .section(let section) = selection { section } else { nil }
  }
  private var category: String? {
    if case .category(let category) = selection { category } else { nil }
  }

  private var entries: [LibraryEntry] {
    let matches = library.entries.filter {
      (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search))
        && (section == .hidden) == library.hidden.contains($0.id)
        && (section != .pinned || library.pinned.contains($0.id))
        && (section != .recent || library.recent.contains($0.id))
        && (category == nil || $0.package.manifest.category == category)
    }
    if section == .recent {
      return matches.sorted {
        (library.recent.firstIndex(of: $0.id) ?? 999)
          < (library.recent.firstIndex(of: $1.id) ?? 999)
      }
    }
    return matches
  }
  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      List(selection: $selection) {
        Section("Library") {
          ForEach(LibrarySection.allCases) { section in
            Label(section.rawValue, systemImage: section.symbol).tag(LibraryFilter.section(section))
          }
        }
        if !library.categories.isEmpty {
          Section("Categories", isExpanded: $categoriesExpanded) {
            ForEach(library.categories, id: \.self) { category in
              Label(category.capitalized, systemImage: LibraryFilter.categorySymbols[category] ?? "tag")
                .tag(LibraryFilter.category(category))
            }
          }
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .background(Color.black.opacity(0.24).ignoresSafeArea())
      .controlSize(.large)
      .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
      .toolbar(removing: sidebarOwnsToolbar ? .sidebarToggle : nil)
      .toolbar { sidebarToolbar }
    } detail: {
      ScrollView {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 220, maximum: 400), spacing: 18)],
          spacing: 22
        ) {
          ForEach(entries) { entry in card(entry) }
        }.padding(20)
      }
      .overlay {
        if entries.isEmpty {
          if !search.isEmpty {
            ContentUnavailableView.search(text: search)
          } else {
            ContentUnavailableView(
              section == .pinned
                ? "No pinned noodlets"
                : section == .recent
                  ? "No recent noodlets"
                  : section == .hidden ? "No hidden noodlets" : "No noodlets",
              systemImage: section?.symbol ?? "square.grid.2x2")
          }
        }
      }
      .mask { ConversationContentTopFade() }
      .navigationTitle(category?.capitalized ?? section?.rawValue ?? "All")
      .toolbar { libraryToolbar }
    }
    .navigationSplitViewStyle(.balanced)
    .background {
      ConversationWallpaper(background: background.background, imageURL: background.imageURL)
        .overlay(alignment: .top) {
          ConversationWindowHeaderShade()
        }
        .ignoresSafeArea()
    }
    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    .onChange(of: library.categories) { _, categories in
      if let category, !categories.contains(category) { selection = .section(.all) }
    }
    .onChange(of: searching) { _, active in if !active { searchFocused = false } }
    .onAppear { columnVisibility = sidebarVisible ? .all : .detailOnly }
    .onChange(of: columnVisibility) { _, value in sidebarVisible = value != .detailOnly }
    .alert(
      AppletBuildIdentity.current.appName,
      isPresented: Binding(
        get: { runtime.error != nil || library.error != nil },
        set: {
          if !$0 {
            runtime.error = nil
            library.error = nil
          }
        }
      )
    ) {
      Button("OK") {
        runtime.error = nil
        library.error = nil
      }
    } message: {
      Text(runtime.error ?? library.error ?? "")
    }
    .confirmationDialog(
      "Move to Trash?", isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } }),
      titleVisibility: .visible
    ) {
      Button("Move to Trash", role: .destructive) {
        guard let package = trashing?.package else { return }
        Task {
          do { try await library.trash(package) } catch { library.error = error.localizedDescription }
        }
      }
    } message: {
      Text("“\(trashing?.title ?? "")” will be moved to the Trash. Its saved data, secrets and permissions will be deleted.")
    }
  }
  /// SwiftUI places its own sidebar toggle last in the sidebar's toolbar section, so
  /// while the sidebar is open it declares the toggle itself to let Open Noodlet
  /// follow it. Column items are hidden with the sidebar; the system toggle and the
  /// detail toolbar's Open Noodlet return then. Toolbar spacers need macOS 26.
  private var sidebarOwnsToolbar: Bool {
    if #available(macOS 26.0, *) { return columnVisibility != .detailOnly }
    return false
  }
  private var openNoodletButton: some View {
    Button { library.choosePackage(open: runtime.open) } label: {
      Label("Open Noodlet", systemImage: "plus")
    }.help("Open Noodlet")
  }
  @ToolbarContentBuilder private var sidebarToolbar: some ToolbarContent {
    if #available(macOS 26.0, *), sidebarOwnsToolbar {
      ToolbarSpacer(.flexible)
      ToolbarItem {
        Button { withAnimation { columnVisibility = .detailOnly } } label: {
          Label("Hide Sidebar", systemImage: "sidebar.leading")
        }.help("Hide Sidebar")
      }
      ToolbarSpacer(.fixed)
      ToolbarItem { openNoodletButton }
    }
  }
  @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
    if !sidebarOwnsToolbar {
      ToolbarItem(id: "applet-open", placement: .automatic) { openNoodletButton }
    }
    if #available(macOS 26.0, *) {
      ToolbarSpacer(.flexible, placement: .automatic)
    } else {
      ToolbarItem(placement: .automatic) { Spacer() }
    }
    searchToolbar
  }
  @ToolbarContentBuilder private var searchToolbar: some ToolbarContent {
    ToolbarItem(id: "applet-search", placement: .automatic) {
      Group {
        if searching {
          HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
            AppletSearchField(text: $search, focused: $searchFocused) {
              searching = false
              search = ""
            }.frame(minWidth: 0)
            Button {
              searching = false
              search = ""
            } label: {
              Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                .foregroundStyle(.secondary)
            }.help("Close Search")
          }
          .padding(.horizontal, 9)
          .frame(minWidth: 120, idealWidth: 240, maxWidth: 240)
          .frame(height: 34)
          .overlay(
            Capsule().strokeBorder(
              .primary.opacity(searchFocused ? 0.4 : 0), lineWidth: 2)
          )
          .buttonStyle(.borderless)
          .transition(.opacity)
        } else {
          Button {
            openSearch()
          } label: {
            Label("Search", systemImage: "magnifyingglass")
          }.help("Search (⌘F)").keyboardShortcut("f", modifiers: .command)
            .transition(.opacity)
        }
      }
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: searching)
    }
  }
  private func openSearch() {
    if searching { searchFocused = true } else { searching = true }
  }
  private func card(_ entry: LibraryEntry) -> some View {
    let cached = library.root.appendingPathComponent("Thumbnails/\(entry.id).png")
    let thumbnail = FileManager.default.fileExists(atPath: cached.path) ? cached
      : ((try? NoodletPackage.child("preview.png", in: entry.package.url)) ?? cached)
    let native = entry.package.manifest.runtime == "swift"
    let running = runtime.sessions.values.contains {
      $0.package.key == entry.id && $0.state == "running"
    }
    return VStack(alignment: .leading, spacing: 0) {
      Button {
        runtime.open(entry.package)
      } label: {
        ZStack {
          LinearGradient(
            colors: native
              ? [
                Color(red: 0.13, green: 0.16, blue: 0.3),
                Color(red: 0.38, green: 0.26, blue: 0.55),
              ]
              : [
                Color(red: 0.2, green: 0.3, blue: 0.28),
                Color(red: 0.53, green: 0.61, blue: 0.39),
              ], startPoint: .topLeading, endPoint: .bottomTrailing)
          if let image = NSImage(contentsOf: thumbnail) {
            NoodletThumbnail(image: image)
          } else {
            Image(
              systemName: entry.package.manifest.symbol
                ?? (native ? "sparkles" : "globe")
            ).font(.system(size: 44, weight: .light)).foregroundStyle(
              .white.opacity(0.8))
          }
          VStack {
            HStack {
              Spacer()
              Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(
                .white
              ).padding(9).background(.black.opacity(0.25), in: Circle())
            }
            Spacer()
          }.padding(12)
        }.frame(height: 160).clipped()
      }.buttonStyle(.plain)
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(entry.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            .help(entry.title)
          Spacer()
          Button {
            library.pin(entry.id)
          } label: {
            Image(systemName: library.pinned.contains(entry.id) ? "pin.fill" : "pin")
              .foregroundStyle(
                library.pinned.contains(entry.id) ? .orange : .secondary)
          }.buttonStyle(.plain)
        }
        Text(entry.package.manifest.summary ?? "A little creation for your computer.").font(
          .system(size: 12)
        ).foregroundStyle(.secondary).lineLimit(2).frame(height: 32, alignment: .topLeading)
        HStack(spacing: 5) {
          Circle().fill(running ? Color.green : Color.secondary.opacity(0.4)).frame(
            width: 5, height: 5)
          Text(running ? "Running" : native ? "Native Swift" : "HTML")
          Spacer()
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 5)
      }.padding(15)
    }.background(
      Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14)
    ).clipShape(RoundedRectangle(cornerRadius: 14)).overlay(
      RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.06))
    )
    .contextMenu {
      Button("Open") { runtime.open(entry.package) }
      if running {
        Button("Stop") {
          for session in runtime.sessions.values where session.package.key == entry.id {
            session.stop()
          }
          runtime.objectWillChange.send()
        }
      }
      if let target = runtime.castTarget(for: entry.id) { NoodletCastMenu(target: target) }
      Button("Reveal Package") {
        NSWorkspace.shared.activateFileViewerSelecting([entry.package.url])
      }
      Button(library.pinned.contains(entry.id) ? "Unpin" : "Pin") { library.pin(entry.id) }
      Button(library.hidden.contains(entry.id) ? "Unhide" : "Hide") { library.hide(entry.id) }
      Divider()
      Button("Move to Trash…") { trashing = entry }.disabled(running)
    }
  }
}

@MainActor private struct AppletFileCommands: Commands {
  let delegate: AppletDelegate
  @ObservedObject var runtime: AppletRuntime
  @Environment(\.openWindow) private var openWindow
  var body: some Commands {
    let action = openWindow
    let _ = delegate.openLibrary = { action(id: "library") }
    CommandGroup(replacing: .newItem) {
      Button("Open Library") { delegate.reopenLibrary() }
      Button("Open Noodlet…") {
        delegate.library.choosePackage(open: delegate.runtime.open)
      }.keyboardShortcut("o")
      if let package = runtime.frontPackage {
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([package.url]) }
        if let target = runtime.castTarget(for: package.key) { NoodletCastMenu(target: target) }
      }
    }
  }
}

/// A running noodlet window that can play full screen on another display.
@MainActor protocol NoodletCastTarget: AnyObject {
  var canCast: Bool { get }
  var isCasting: Bool { get }
  func play(on screen: NSScreen)
  func bringBack()
}
extension WebRunner: NoodletCastTarget {}
extension NativeRunner: NoodletCastTarget {}

/// Plays a noodlet full screen on a display. A TV becomes one through AirPlay, which macOS
/// only lets people add themselves, so the menu ends with the way to do that.
@MainActor private struct NoodletCastMenu: View {
  let target: NoodletCastTarget
  var body: some View {
    if target.isCasting {
      Button("Bring Back to This Mac") { target.bringBack() }
    } else if target.canCast {
      Menu("Play On") {
        ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { _, screen in
          Button(screen.localizedName) { target.play(on: screen) }
        }
        if !NSScreen.screens.isEmpty { Divider() }
        Button("Add TV or Display…") { NSWorkspace.shared.open(NoodletCast.displaysSettings) }
          .help("Use an Apple TV or AirPlay TV as a separate display.")
      }
    }
  }
}

/// A noodlet's preview image, filling the card's tile. An aspect-fill image is wider than the
/// tile, so it rides in an overlay: the card takes its width from the grid's column, not from
/// the preview, and never spills over the card beside it.
struct NoodletThumbnail: View {
  let image: NSImage
  var body: some View {
    Color.clear.frame(height: 160).overlay {
      Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
    }.clipped()
  }
}
