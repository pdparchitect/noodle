import AppKit
import AppletBridge
import AppletCore
import SwiftUI

@main struct NoodleAppletApp: App {
  @NSApplicationDelegateAdaptor(AppletDelegate.self) private var delegate
  @AppStorage("showMenuBar") private var showMenuBar = false

  var body: some Scene {
    Window("Noodle Applet", id: "library") {
      LibraryView(library: delegate.library, runtime: delegate.runtime)
        .frame(minWidth: 850, minHeight: 580)
        .preferredColorScheme(.dark)
        .task {
          if CommandLine.arguments.contains("--updater-ui-test") {
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
    .defaultLaunchBehavior(
      CommandLine.arguments.contains("--noodle-background") ? .suppressed : .presented
    )
    .restorationBehavior(
      CommandLine.arguments.contains("--noodle-background") ? .disabled : .automatic
    )
    .defaultSize(width: 1080, height: 720)
    .windowToolbarStyle(.unified(showsTitle: false))
    .commands {
      CommandGroup(after: .appSettings) { AppletCheckForUpdatesButton() }
      CommandGroup(replacing: .appInfo) {
        Button("About Noodle Applet") {
          NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Noodle Applet"])
        }
      }
      CommandGroup(replacing: .help) {
        Button("Noodle Applet Help") { NSWorkspace.shared.open(AppletLinks.repository) }
      }
      AppletFileCommands(delegate: delegate)
    }
    Settings {
      AppletSettingsView().preferredColorScheme(.dark)
    }
    .windowResizability(.contentSize)
    MenuBarExtra("Noodle Applet", systemImage: "square.grid.2x2.fill", isInserted: $showMenuBar) {
      AppletMenu(library: delegate.library, runtime: delegate.runtime)
    }
  }
}

enum AppletLinks {
  static let repository = URL(string: "https://github.com/pdparchitect/noodle")!
}

private struct AppletMenu: View {
  @ObservedObject var library: AppletLibrary
  @ObservedObject var runtime: AppletRuntime
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("Open Library") {
      openWindow(id: "library")
      NSApp.activate(ignoringOtherApps: true)
    }
    Divider()
    ForEach(library.pinned, id: \.self) { key in
      if let entry = library.entries.first(where: { $0.id == key }) {
        Button {
          runtime.open(entry.package)
        } label: {
          Label(entry.title, systemImage: "pin.fill")
        }
      }
    }
    if library.entries.contains(where: { library.pinned.contains($0.id) }) { Divider() }
    ForEach(library.recent.filter { !library.pinned.contains($0) }.prefix(8), id: \.self) {
      key in
      if let entry = library.entries.first(where: { $0.id == key }) {
        Button(entry.title) { runtime.open(entry.package) }
      }
    }
    Divider()
    Button("Quit Noodle Applet") { NSApp.terminate(nil) }.keyboardShortcut("q")
  }
}

@MainActor final class AppletDelegate: NSObject, NSApplicationDelegate {
  var openLibrary: (() -> Void)?
  let library = AppletLibrary()
  lazy var runtime = AppletRuntime(library: library)

  func applicationDidBecomeActive(_ notification: Notification) {
    // Quiet agent launches must not display update prompts.
    AppletUpdater.shared.start()
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    if CommandLine.arguments.contains("--updater-ui-test") {
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(250))
        reopenLibrary()
      }
    } else {
      runtime.startServer()
    }
    if CommandLine.arguments.contains("--noodle-background") { NSApp.hide(nil) }
  }

  private func reopenLibrary() {
    if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "library" }) {
      window.makeKeyAndOrderFront(nil)
    } else {
      openLibrary?()
    }
    NSApp.unhide(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    reopenLibrary()
    return true
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationWillTerminate(_ notification: Notification) { runtime.shutdown() }
  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      do {
        try library.grant(url)
        runtime.open(try NoodletPackage(url: url))
      } catch { runtime.error = error.localizedDescription }
    }
  }
}

private enum LibrarySection: String, CaseIterable, Identifiable {
  case all = "All"
  case recent = "Recent"
  case pinned = "Pinned"
  var id: Self { self }
  var symbol: String {
    switch self {
    case .all: "square.grid.2x2"
    case .recent: "clock"
    case .pinned: "pin"
    }
  }
}

private struct LibraryView: View {
  @ObservedObject var library: AppletLibrary
  @ObservedObject var runtime: AppletRuntime
  @State private var search = ""
  @State private var searching = false
  @State private var searchFocused = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var selection: LibrarySection? = .all
  @State private var columnVisibility = NavigationSplitViewVisibility.all
  @AppStorage("AppletSidebarVisible") private var sidebarVisible = true

  private var entries: [LibraryEntry] {
    let matches = library.entries.filter {
      (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search))
        && (selection != .pinned || library.pinned.contains($0.id))
        && (selection != .recent || library.recent.contains($0.id))
    }
    if selection == .recent {
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
            Label(section.rawValue, systemImage: section.symbol).tag(section)
          }
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .background(Color.black.opacity(0.24).ignoresSafeArea())
      .controlSize(.large)
      .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
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
              selection == .pinned
                ? "No pinned noodlets"
                : selection == .recent ? "No recent noodlets" : "No noodlets",
              systemImage: selection?.symbol ?? "square.grid.2x2")
          }
        }
      }
      .navigationTitle(selection?.rawValue ?? "All")
      .toolbar { libraryToolbar }
    }
    .navigationSplitViewStyle(.balanced)
    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    .onChange(of: searching) { _, active in if !active { searchFocused = false } }
    .onAppear { columnVisibility = sidebarVisible ? .all : .detailOnly }
    .onChange(of: columnVisibility) { _, value in sidebarVisible = value != .detailOnly }
    .alert(
      "Noodle Applet",
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
  }
  @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
    ToolbarItem(id: "applet-open", placement: .automatic) {
      Button { library.choosePackage(open: runtime.open) } label: {
        Label("Open Noodlet", systemImage: "folder")
      }.help("Open Noodlet")
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
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(
              height: 160
            ).clipped()
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
          Text(entry.title).font(.system(size: 15, weight: .semibold))
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
      Button("Reveal Package") {
        NSWorkspace.shared.activateFileViewerSelecting([entry.package.url])
      }
      Button(library.pinned.contains(entry.id) ? "Unpin" : "Pin") { library.pin(entry.id) }
    }
  }
}

@MainActor private struct AppletFileCommands: Commands {
  let delegate: AppletDelegate
  @Environment(\.openWindow) private var openWindow
  var body: some Commands {
    let action = openWindow
    let _ = delegate.openLibrary = { action(id: "library") }
    CommandGroup(replacing: .newItem) {
      Button("Open Noodlet…") {
        delegate.library.choosePackage(open: delegate.runtime.open)
      }.keyboardShortcut("o")
    }
  }
}
