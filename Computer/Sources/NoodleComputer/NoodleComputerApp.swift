import AppKit
import ComputerBridge
import ComputerCore
import ComputerEngine
import ComputerExternal
import NoodleLaunchChecks
import NoodleSettingsUI
import NoodleWallpaper
import SwiftUI
import UniformTypeIdentifiers
import Virtualization

/// Claims the app's single running copy before SwiftUI makes its delegate, which opens its data.
@main enum NoodleComputerEntry {
    static func main() {
        AppInstance.claim()
        NoodleComputerApp.main()
    }
}

struct NoodleComputerApp: App {
  @NSApplicationDelegateAdaptor(ComputerAppDelegate.self) private var delegate
  @ObservedObject private var visibility = CompanionAppVisibility.shared
  var body: some Scene {
    Window(ComputerAppIdentity.name, id: "library") {
      ComputerRootView()
        .frame(minWidth: 850, minHeight: 580)
        .background(ComputerLibraryWindowHost(library: delegate.libraryWindow))
    }
    // A quiet start from Noodle arrives as a URL, so the scene cannot tell it apart
    // from a user launch; the delegate opens the library for a user launch.
    .defaultLaunchBehavior(.suppressed)
    .restorationBehavior(.disabled)
    .handlesExternalEvents(matching: [])
    .defaultSize(width: 1080, height: 720)
    .windowToolbarStyle(.unified(showsTitle: false))
    .commands {
      CommandGroup(replacing: .appInfo) {
        Button("About \(ComputerAppIdentity.name)") {
          NSApplication.shared.orderFrontStandardAboutPanel(options: [.applicationName: ComputerAppIdentity.name])
        }
        ComputerCheckForUpdatesButton()
      }
      CommandGroup(replacing: .help) {
        Button("\(ComputerAppIdentity.name) Help") {
          NSWorkspace.shared.open(URL(string: "https://github.com/pdparchitect/noodle")!)
        }
        Divider()
        IssueReportButtons(area: "Noodle Computer")
      }
      ComputerFileCommands(delegate: delegate)
      ComputerSpaceCommands()
    }
    Settings {
      ComputerSettingsView()
    }
    .windowResizability(.contentSize)
    MenuBarExtra(isInserted: $visibility.showMenuBar) {
      ComputerMenu(delegate: delegate)
    } label: {
      CompanionMenuBarLabel(ComputerAppIdentity.name)
    }
  }
}

@MainActor private struct ComputerFileCommands: Commands {
  let delegate: ComputerAppDelegate
  @Environment(\.openWindow) private var openWindow
  var body: some Commands {
    let action = openWindow
    let _ = delegate.openLibrary = { action(id: "library") }
    CommandGroup(replacing: .newItem) {
      Button("New Linux Container") { NotificationCenter.default.post(name: .newComputer, object: nil) }
        .keyboardShortcut("n")
      Button("New Local Mac") { NotificationCenter.default.post(name: .newLocalMac, object: nil) }
      if #available(macOS 27, *) {
        Divider()
        Button("New Windows") { NotificationCenter.default.post(name: .newWindows, object: nil) }
      }
      Divider()
      Button("New SSH Computer") { NotificationCenter.default.post(name: .newSSH, object: nil) }
    }
  }
}

@MainActor private struct ComputerSpaceCommands: Commands {
  @ObservedObject private var library = ComputerLibraryState.shared
  var body: some Commands {
    if let store = library.store { Spaces(store: store) }
  }
  private struct Spaces: Commands {
    @ObservedObject var store: ComputerStore
    var body: some Commands { CompanionSpaceCommands(hasHub: store.sessions.contains { $0.computer.hub == true }) }
  }
}

extension Notification.Name {
  static let newComputer = Self("NoodleComputer.New")
  static let newLocalMac = Self("NoodleComputer.NewLocalMac")
  static let newWindows = Self("NoodleComputer.NewWindows")
  static let newSSH = Self("NoodleComputer.NewSSH")
}

/// Launch checks, matched by digest so a built app never names them. Only the first ships in a release;
/// the rest need a build with `NOODLE_DEV_HOOKS`.
enum ComputerLaunchCheck {
  static let updaterUI = "33f8b12621881e80aeaf87bc1d61ef880882e6b5cf0d3a2a1fc3e7ee99b42609"  // --updater-ui-test
  #if NOODLE_DEV_HOOKS
  static let keepTestWindow = "64d77565ca3929a74ec3ae6cc4be7ac83d4d31d42b8771dc2daf79002c3e2ec9"  // --keep-test-window
  static let files = "b476bd153e380b4ef626b592541a784d4a934f00b3da9abd390022616fb25413"  // --files-test
  static let providerIntegration = "27477bd84260b828a28d305cd92dbea1df662af022a8d9add98293a283e06e74"  // --provider-integration-test
  static let providerSnapshot = "749fbf076ee2440829bcfa605e5b6740c53e8e7ff999769c1f838b89a446af69"  // --provider-snapshot-test
  static let libraryLayout = "0b5e4c1010bd557a80ea521c33f0befb7c4ad203aef42c3897d23cf0a2752950"  // --library-layout-test
  static let emptyLibrary = "e7f8ebc7c2f3a51e13267fc9acb404fd6c13d067256a888246a6fdc0dd318c08"  // --empty-library-test
  static let appearancePreview = "234940ef2db5871ab2be6d23dcc4ba7d7ea65cda9729e93c29172f74b01afcd5"  // --appearance-preview
  static let localMacCreationPreview = "55cd0e40b54036764c3278c167f0de3b46a84abbf604e2669cdb1f9d40549875"  // --localmac-creation-preview
  static let creationForm = "003908a56a80c8ecc27c41d1cbdfdddc0711263d1a64ea862af09978140a5db6"  // --creation-form-test
  static let desktopSmoke = "cd0fe779f3182dbfeaab29ec25187cc9e460f3feaaee07d10e3c5d92a38d9365"  // --desktop-smoke-test
  static let downloadProgress = "fe8db07e2c84c36e200adba9cf030a79e2ffb337f46d9be773ce9b44416067c7"  // --download-progress-test
  static let linuxBoot = "fab92a2ac3952a0a9097d0d5cf8589ce610487db7f1f97f1995513b9a5883876"  // --linux-boot-test
  static let configuration = "cd7ab844a5c0dad4ac41d0324b14251ed995c74ebaad8bf5410abfbf6669656c"  // --configuration-test
  static let overlayUI = "abd5eb336517172b6564e631fb381ad18580e176d5624fba7d036b975cc1d5ed"  // --overlay-ui-test
  static let latestImages = "a0899d5327b8553fa41ef0d6326a2d0d859b2ef46923cfb4f15eefaa4d531d06"  // --latest-images-test
  static let overlay = "093126f40abeca909f38764a45026f341ab650542637529e04ac147aa8ad39b3"  // --overlay-test
  static let selfTest = "eaf0760032ad43d55e3bbcf4d5153069c67652bdeb968530d47be859a94ef5df"  // --self-test
  static let offline = "aff7d00b56394f5a96dca22be6856e0950b37524abb5b2ef434d27981a0586f1"  // --offline
  /// A failure of any of these ends the process with an error instead of showing it in the window.
  static let exitOnFailure = [
    updaterUI, emptyLibrary, libraryLayout, providerIntegration, creationForm,
    localMacCreationPreview, desktopSmoke, selfTest, overlay, latestImages, configuration, downloadProgress
  ]
  static var keepsTestWindow: Bool { requested(keepTestWindow) }
  /// Every check that runs in place of the app; the rest only modify one of these.
  private static let verificationRuns = [
    updaterUI, files, providerIntegration, providerSnapshot, libraryLayout, emptyLibrary,
    appearancePreview, localMacCreationPreview, creationForm, desktopSmoke, downloadProgress,
    linuxBoot, configuration, overlayUI, latestImages, overlay, selfTest
  ]
  #else
  static let exitOnFailure = [updaterUI]
  static let keepsTestWindow = false
  private static let verificationRuns = [updaterUI]
  #endif
  static var isVerificationRun: Bool { verificationRuns.contains(where: requested) }
  static func requested(_ digest: String) -> Bool { LaunchChecks.current.contains(digest) }
}

@MainActor final class ComputerAppDelegate: NSObject, NSApplicationDelegate {
  static var store: ComputerStore? {
    get { ComputerLibraryState.shared.store }
    set { ComputerLibraryState.shared.store = newValue }
  }
  let libraryWindow = ComputerLibraryWindow()
  var openLibrary: (() -> Void)? {
    didSet {
      if needsLibrary, openLibrary != nil {
        needsLibrary = false
        DispatchQueue.main.async { [weak self] in self?.presentLibrary() }
      }
    }
  }
  private var needsLibrary = false
  /// Set by any URL, the quiet start included; the library then stays closed.
  private(set) var openedDocument = false
  private var documentRequest = UUID()
  private var documentStarts: [UUID: Task<Void, Never>] = [:]
  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      if url == ComputerLaunch.backgroundURL() {
        openedDocument = true
        continue
      }
      if url == ComputerLaunch.updateCheckURL() {
        openedDocument = true
        reopenLibrary()
        ComputerUpdater.shared.start()
        ComputerUpdater.shared.check()
        continue
      }
      do {
        guard ComputerLink.build(in: url) == .current, let target = ComputerLink.target(in: url) else {
          throw ComputerError("This link is not for \(ComputerAppIdentity.name).")
        }
        let store = try Self.loadLibrary()
        let session = try store.selectComputer(target.computer, view: target.view)
        openedDocument = true
        application.unhide(nil)
        application.activate(ignoringOtherApps: true)
        presentLibrary()
        let request = UUID()
        documentRequest = request
        let start = documentStarts[session.id] ?? Task { [weak self] in
          if session.phase.canStart { await store.start(session) }
          self?.documentStarts.removeValue(forKey: session.id)
        }
        documentStarts[session.id] = start
        Task {
          await start.value
          guard documentRequest == request, store.selection == session.id else { return }
          await store.selectDisplay(target.view == "web" ? .desktop : .terminal, in: session)
        }
      } catch {
        let alert = NSAlert(error: error)
        alert.runModal()
      }
    }
  }
  func reopenLibrary() {
    presentLibrary()
    NSApp.unhide(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    reopenLibrary()
    return true
  }
  private func presentLibrary() {
    if libraryWindow.focus() {
      needsLibrary = false
    } else if let openLibrary {
      needsLibrary = false
      openLibrary()
    } else {
      needsLibrary = true
    }
  }
  func applicationDidBecomeActive(_ notification: Notification) {
    // Quiet agent-driven provider launches must not show update prompts.
    ComputerUpdater.shared.start()
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    WindowFocusGuard.shared.start()
    OrphanedSheetSweeper.shared.start()
    CompanionAppVisibility.shared.start(permitsDock: !ComputerLaunchCheck.isVerificationRun)
    #if NOODLE_DEV_HOOKS
    // scripts/verify-launch-hooks.sh rejects a release that carries this marker.
    NSLog("noodle.development-hooks.enabled")
    #endif
    guard CommandLine.arguments.contains("--noodle-background") else {
      // Checks run in the library window, which the scene no longer opens on launch.
      guard !ComputerLaunchCheck.isVerificationRun else { presentLibrary(); return }
      // Launch URLs can arrive just after this, so decide on the next turn.
      let userLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool == true
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        if userLaunch, !self.openedDocument { self.presentLibrary() }
        // The provider can own the library without creating a SwiftUI window.
        do { _ = try Self.loadLibrary() }
        catch { fputs("Computer provider: \(error.localizedDescription)\n", stderr) }
      }
      return
    }
    // Also cover Launch Services reopening a previously registered single-window
    // app. This affects only this process; an explicit later open unhides it.
    if !openedDocument { NSApp.hide(nil) }
    #if NOODLE_DEV_HOOKS
    if ComputerLaunchCheck.requested(ComputerLaunchCheck.providerIntegration) {
      Task {
        do { try await ComputerSmokeTest.checkProvider(); NSApp.terminate(nil) }
        catch { fputs("PROVIDER TEST FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
      }
      return
    }
    #endif
    // The provider can own the library without creating a SwiftUI window.
    do { _ = try Self.loadLibrary() }
    catch { fputs("Computer provider: \(error.localizedDescription)\n", stderr) }
  }
  static func loadLibrary() throws -> ComputerStore {
    if let store { return store }
    let model = try ComputerStore()
    model.provider = try ComputerProvider(store: model)
    store = model
    ComputerExternalService.start(store: model)
    model.wakeLocalMacService()
    return model
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let store = Self.store else { return .terminateNow }
    // Always finish quitting, even if a guest or shutdown API is unresponsive.
    var replied = false
    let reply = {
      guard !replied else { return }
      replied = true
      sender.reply(toApplicationShouldTerminate: true)
    }
    Task {
      await store.shutdown()
      reply()
    }
    // Windows takes a while to shut down, and is worse off cut short.
    let running = store.sessions.contains { $0.windowsRuntime != nil }
    Task {
      try? await Task.sleep(for: .seconds(running ? 30 : 10))
      reply()
    }
    return .terminateLater
  }
}

struct ComputerRootView: View {
  @State private var store: ComputerStore?
  @State private var startupError: String?
  var body: some View {
    Group {
      if let store {
        ComputerLibraryView(store: store)
      } else if let startupError {
        ContentUnavailableView(
          "Cannot Open Computer Library", systemImage: "exclamationmark.triangle",
          description: Text(startupError))
          .toolbar { CompanionSettingsToolbarItem(spacing: .flexible) }
      } else {
        ProgressView("Opening computer library…")
      }
    }
    .task {
      guard store == nil, startupError == nil else { return }
      do {
        #if NOODLE_DEV_HOOKS
        if ComputerLaunchCheck.requested(ComputerLaunchCheck.files) {
          let model = try await ComputerFilesSmokeTest.run()
          store = model; ComputerAppDelegate.store = model
          if !ComputerLaunchCheck.keepsTestWindow { NSApplication.shared.terminate(nil) }
          return
        }
        #endif
        if ComputerLaunchCheck.requested(ComputerLaunchCheck.updaterUI) {
          try await ComputerSmokeTest.checkUpdaterUI()
          if !ComputerLaunchCheck.keepsTestWindow { NSApplication.shared.terminate(nil) }
          return
        }
        if CommandLine.arguments.contains("--noodle-background") {
          // The delegate hides the initial background launch. Do not hide here:
          // this view may first be created by a later explicit Open from Noodle.
          // Launch restoration must never run a second provider/fixture through
          // the view. The app delegate owns background initialization.
          #if NOODLE_DEV_HOOKS
          guard !ComputerLaunchCheck.requested(ComputerLaunchCheck.providerIntegration) else { return }
          #endif
          store = try ComputerAppDelegate.loadLibrary()
          return
        }
        #if NOODLE_DEV_HOOKS
        if ComputerLaunchCheck.requested(ComputerLaunchCheck.providerIntegration) {
          try await ComputerSmokeTest.checkProvider()
          NSApplication.shared.terminate(nil)
          return
        }
        if ComputerLaunchCheck.requested(ComputerLaunchCheck.libraryLayout) {
          try await ComputerSmokeTest.checkLibraryLayout()
          NSApplication.shared.terminate(nil)
          return
        }
        if ComputerLaunchCheck.requested(ComputerLaunchCheck.emptyLibrary) {
          try await ComputerSmokeTest.checkEmptyLibraryBackground()
          NSApplication.shared.terminate(nil)
          return
        }
        if ComputerLaunchCheck.requested(ComputerLaunchCheck.appearancePreview) {
          try await ComputerSmokeTest.checkAppearancePreview()
          NSApplication.shared.terminate(nil)
          return
        }
        if ComputerLaunchCheck.requested(ComputerLaunchCheck.localMacCreationPreview) {
          try await LocalMacCreationPreview.run()
          NSApplication.shared.terminate(nil)
          return
        }
        if ComputerLaunchCheck.requested(ComputerLaunchCheck.creationForm) {
          try await ComputerSmokeTest.checkCreationForm()
          NSApplication.shared.terminate(nil)
          return
        }
        if ComputerLaunchCheck.requested(ComputerLaunchCheck.desktopSmoke) {
          try await ComputerSmokeTest.checkDesktop()
          NSApplication.shared.terminate(nil)
          return
        }
        if ComputerLaunchCheck.requested(ComputerLaunchCheck.downloadProgress) {
          try await ComputerSmokeTest.checkDownloadProgressAndCancellation()
          NSApplication.shared.terminate(nil)
          return
        }
        if ComputerLaunchCheck.requested(ComputerLaunchCheck.linuxBoot) {
          let model = try await ComputerSmokeTest.linuxBootFixture()
          store = model
          ComputerAppDelegate.store = model
          return
        }
        if ComputerLaunchCheck.requested(ComputerLaunchCheck.configuration) {
          try await ComputerSmokeTest.checkMacConfiguration()
          NSApplication.shared.terminate(nil)
          return
        }
        if ComputerLaunchCheck.requested(ComputerLaunchCheck.overlayUI) {
          let model = try ComputerOverlaySmokeTest.makeUIStore()
          store = model
          ComputerAppDelegate.store = model
          NSApp.activate()
          return
        }
        if ComputerLaunchCheck.requested(ComputerLaunchCheck.latestImages) {
          try await ComputerOverlaySmokeTest.checkLatestTemplates()
          NSApplication.shared.terminate(nil)
          return
        }
        if ComputerLaunchCheck.requested(ComputerLaunchCheck.overlay) {
          try await ComputerOverlaySmokeTest.run()
          NSApplication.shared.terminate(nil)
          return
        }
        if ComputerLaunchCheck.requested(ComputerLaunchCheck.selfTest) {
          try await ComputerSmokeTest.run(
            networkEnabled: !ComputerLaunchCheck.requested(ComputerLaunchCheck.offline))
          NSApplication.shared.terminate(nil)
          return
        }
        #endif
        let model = try ComputerAppDelegate.loadLibrary()
        store = model
      } catch {
        startupError = error.localizedDescription
        if ComputerLaunchCheck.exitOnFailure.contains(where: ComputerLaunchCheck.requested) {
          fputs("COMPUTER SELF-TEST FAILED: \(error.localizedDescription)\n", stderr)
          exit(1)
        }
      }
    }
  }
}

struct ComputerLibraryView: View {
  @ObservedObject var store: ComputerStore
  @State private var showingNew = false
  @State private var showingLocalMac = false
  @State private var showingWindows = false
  @State private var showingSSH = false
  @State private var searchText = ""
  @State private var columnVisibility = NavigationSplitViewVisibility.all
  @AppStorage("ComputerSidebarVisible") private var sidebarVisible = true
  @AppStorage(CompanionSpace.key) private var chosenSpace = CompanionSpace.personal
  @Environment(\.colorScheme) private var colorScheme
  @ObservedObject private var external = ComputerExternalService.shared?.gate ?? ExternalGate(url: nil, prompter: nil)

  private var space: CompanionSpace { chosenSpace.shown(hasHub: store.sessions.contains { $0.computer.hub == true }) }
  private var shownSessions: [ComputerSession] { store.sessions.filter { ($0.computer.hub == true) == (space == .hub) } }

  private var filteredSessions: [ComputerSession] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return shownSessions.filter {
      query.isEmpty || $0.computer.name.localizedCaseInsensitiveContains(query)
        || $0.computer.displayType.localizedCaseInsensitiveContains(query)
    }
  }

  private func rows(_ sessions: [ComputerSession]) -> some View {
    ForEach(sessions) { session in
      ComputerRow(store: store, session: session).tag(session.id)
    }
  }

  private var createMenu: some View {
    Menu {
      Button("New Linux Container", systemImage: "desktopcomputer") { showingNew = true }
        .keyboardShortcut("n", modifiers: .command)
      Button("New Local Mac", systemImage: "person.crop.rectangle") { showingLocalMac = true }
      if #available(macOS 27, *) {
        Divider()
        Button("New Windows", systemImage: ComputerKind.windows.symbol) { showingWindows = true }
      }
      Divider()
      Button("New SSH Computer", systemImage: ComputerKind.ssh.symbol) { showingSSH = true }
    } label: {
      Label("Create", systemImage: "plus")
    }.help("Create Computer")
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      List(selection: $store.selection) {
        let created = Set(external.grants.callers.flatMap { $0.resources.filter(\.created).map(\.id) })
        ForEach(Array(ComputerExternalService.sidebar(filteredSessions, created: created, space: space).enumerated()), id: \.offset) { _, section in
          Section(section.title) { rows(section.sessions) }
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .background(Color.black.opacity(colorScheme == .dark ? 0.24 : 0.04).ignoresSafeArea())
      .searchable(text: $searchText, placement: .sidebar, prompt: "Search")
      .controlSize(.large)
      .navigationSplitViewColumnWidth(min: 280, ideal: 326, max: 380)
      .overlay {
        if !store.sessions.isEmpty && filteredSessions.isEmpty {
          ContentUnavailableView.search(text: searchText)
        }
      }
      // SwiftUI places its own sidebar toggle last in the sidebar's toolbar section, so
      // while the sidebar is open it declares the toggle itself to let Create follow it.
      // Column items are hidden with the sidebar; the system toggle and the window
      // toolbar's Create return then.
      .toolbar(removing: columnVisibility == .detailOnly ? nil : .sidebarToggle)
      .toolbar {
        if columnVisibility != .detailOnly {
          ToolbarSpacer(.flexible)
          ToolbarItem {
            Button { withAnimation { columnVisibility = .detailOnly } } label: {
              Label("Hide Sidebar", systemImage: "sidebar.leading")
            }.help("Hide Sidebar")
          }
          ToolbarSpacer(.fixed)
          ToolbarItem { createMenu }
        }
      }
    } detail: {
      if let session = store.selected {
        ComputerDetailView(store: store, session: session,
                           sidebarCollapsed: columnVisibility == .detailOnly).id(session.id)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ContentUnavailableView {
          Label("Your own computers.", systemImage: "desktopcomputer")
        } description: {
          Text("Create a computer to get started.")
        }
        .toolbar { CompanionSettingsToolbarItem(spacing: .flexible) }
      }
    }
    .navigationSplitViewStyle(.balanced)
    .background {
      // Keep the wallpaper's identity when selection changes or becomes empty.
      ComputerWindowWallpaper(store: store).ignoresSafeArea()
    }
    .background(ComputerWindowCompositing())
    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    .toolbar {
      if columnVisibility == .detailOnly {
        ToolbarItem(placement: .navigation) { createMenu }
      }
    }
    .onAppear { columnVisibility = sidebarVisible ? .all : .detailOnly }
    .onChange(of: columnVisibility) { _, value in sidebarVisible = value != .detailOnly }
    .sheet(isPresented: $showingNew) { NewComputerView(store: store) }
    .sheet(isPresented: $showingLocalMac) { NewLocalMacView(store: store) }
    .sheet(isPresented: $showingSSH) { NewSSHComputerView(store: store) }
    .sheet(isPresented: $showingWindows) {
      if #available(macOS 27, *) { NewWindowsView(store: store) }
    }
    .onReceive(NotificationCenter.default.publisher(for: .newComputer)) { _ in showingNew = true }
    .onReceive(NotificationCenter.default.publisher(for: .newLocalMac)) { _ in showingLocalMac = true }
    .onReceive(NotificationCenter.default.publisher(for: .newSSH)) { _ in showingSSH = true }
    .onReceive(NotificationCenter.default.publisher(for: .newWindows)) { _ in
      if #available(macOS 27, *) { showingWindows = true }
    }
    .onChange(of: store.selection, initial: true) { _, id in
      UserDefaults.standard.set(id?.uuidString, forKey: "SelectedComputer")
      // A computer opened from elsewhere brings its space along.
      if let session = store.selected, (session.computer.hub == true) != (space == .hub) {
        chosenSpace = session.computer.hub == true ? .hub : .personal
      }
    }
    .onChange(of: shownSessions.map(\.id)) { _, ids in
      if !ids.contains(store.selection ?? UUID()) { store.selection = ids.first }
    }
    .task {
      while !Task.isCancelled {
        await store.checkImageUpdates()
        try? await Task.sleep(for: .seconds(12 * 60 * 60))
      }
    }
    .alert(
      store.errorRecovery?.title ?? ComputerAppIdentity.name,
      isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })
    ) {
      if let recovery = store.errorRecovery {
        Button(recovery.actionTitle) {
          store.error = nil
          do { try recovery.open() } catch { store.error = error.localizedDescription }
        }
        Button("Cancel", role: .cancel) { store.error = nil }
      } else {
        Button("OK") { store.error = nil }
      }
    } message: {
      Text(store.error ?? "")
    }
  }
}

struct ComputerRow: View {
  @ObservedObject var store: ComputerStore
  @ObservedObject var session: ComputerSession
  @State private var editing = false
  @State private var deleting = false
  @State private var changingBackground = false
  @State private var stopping = false
  @State private var updating = false
  var body: some View {
    HStack(spacing: 10) {
      ZStack(alignment: .bottomTrailing) {
        ComputerIcon(appearance: session.computer.appearance ?? .init(), symbol: session.computer.displaySymbol, size: 42)
        Circle().fill(statusColor).frame(width: 10, height: 10)
          .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
          .help(session.phase.label)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(session.computer.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
        Text(session.computer.displayType).font(.system(size: 12.5)).foregroundStyle(.secondary)
          .lineLimit(1)
        if session.imageUpdateAvailable {
          Text("Upgrade available").font(.system(size: 11.5)).foregroundStyle(.orange).lineLimit(1)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(height: 66)
    .contentShape(Rectangle())
    .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
    .listRowSeparator(.visible, edges: .bottom)
    .listRowSeparatorTint(Color.primary.opacity(0.12))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(session.computer.name), \(session.computer.displayType), \(session.phase.label)")
    .contextMenu {
      Button("Edit Computer…", systemImage: "slider.horizontal.3") { editing = true }
      Button("Change Background…", systemImage: "photo") { changingBackground = true }
      Divider()
      if session.offersImageUpgrade {
        ComputerImageUpdateButton(session: session) { updating = true }
        Divider()
      }
      Button(session.phase == .running ? "Stop" : "Start", systemImage: session.phase == .running ? "power" : "play.fill") {
        if session.phase == .running { stopping = true }
        else { Task { await store.start(session) } }
      }.disabled(session.phase.busy)
      Divider()
      Button("Delete Computer", systemImage: "trash", role: .destructive) { deleting = true }
        .disabled(!session.canDelete)
    }
    .computerImageUpdateConfirmation(store: store, session: session, isPresented: $updating)
    .sheet(isPresented: $editing) { EditComputerView(store: store, session: session) }
    .sheet(isPresented: $changingBackground) {
      ComputerAppearanceSheet(appearance: Binding(
        get: { session.computer.appearance ?? .init() },
        set: { store.rename(session, name: session.computer.name, appearance: $0) }),
        directory: store.library.directory(for: session.id))
    }
    .alert(ComputerDeletion.title(session.computer), isPresented: $deleting) {
      Button("Cancel", role: .cancel) {}
      Button(ComputerDeletion.action(session.computer), role: .destructive) { store.remove(session) }
    } message: { Text(ComputerDeletion.message(session.computer)) }
    .computerStopConfirmation(isPresented: $stopping, name: session.computer.name) {
      guard session.phase == .running else { return }
      Task { await store.stop(session) }
    }
  }

  private var statusColor: Color {
    switch session.phase {
    case .running: .green
    case .starting, .stopping, .updating, .setupRequired: .orange
    case .failed: .red
    case .stopped: .gray
    }
  }
}
