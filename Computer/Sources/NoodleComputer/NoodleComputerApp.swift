import AppKit
import ComputerBridge
import ComputerCore
import ComputerExternal
import NoodleLaunchChecks
import NoodleWallpaper
import SwiftUI
import NoodleSettingsUI
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
      CommandGroup(after: .appSettings) { ComputerCheckForUpdatesButton() }
      CommandGroup(replacing: .appInfo) {
        Button("About \(ComputerAppIdentity.name)") {
          NSApplication.shared.orderFrontStandardAboutPanel(options: [.applicationName: ComputerAppIdentity.name])
        }
      }
      CommandGroup(replacing: .help) {
        Button("\(ComputerAppIdentity.name) Help") {
          NSWorkspace.shared.open(URL(string: "https://github.com/pdparchitect/noodle")!)
        }
      }
      ComputerFileCommands(delegate: delegate)
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
    }
  }
}

extension Notification.Name {
  static let newComputer = Self("NoodleComputer.New")
  static let newLocalMac = Self("NoodleComputer.NewLocalMac")
  static let newWindows = Self("NoodleComputer.NewWindows")
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
  static let windows = "c562e5dea2f17ee2f2ee86b14c618a6cc35bcd5e86c1a1a00c7c875c1b8bd4b1"  // --windows-test
  /// A failure of any of these ends the process with an error instead of showing it in the window.
  static let exitOnFailure = [
    updaterUI, emptyLibrary, libraryLayout, providerIntegration, creationForm,
    localMacCreationPreview, desktopSmoke, selfTest, overlay, latestImages, configuration, downloadProgress, windows
  ]
  static var keepsTestWindow: Bool { requested(keepTestWindow) }
  /// Every check that runs in place of the app; the rest only modify one of these.
  private static let verificationRuns = [
    updaterUI, files, providerIntegration, providerSnapshot, libraryLayout, emptyLibrary,
    appearancePreview, localMacCreationPreview, creationForm, desktopSmoke, downloadProgress,
    linuxBoot, configuration, overlayUI, latestImages, overlay, selfTest, windows
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
        if ComputerLaunchCheck.requested(ComputerLaunchCheck.windows) {
          guard #available(macOS 27, *) else { throw ComputerError("Windows computers need macOS 27.") }
          let model = try WindowsCheck.fixture()
          store = model
          ComputerAppDelegate.store = model
          WindowsCheck.start(model)
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
  @State private var searchText = ""
  @State private var columnVisibility = NavigationSplitViewVisibility.all
  @AppStorage("ComputerSidebarVisible") private var sidebarVisible = true
  /// People under Hub whose computers are folded away.
  @State private var foldedPeople: Set<UUID> = []
  @Environment(\.colorScheme) private var colorScheme
  @ObservedObject private var external = ComputerExternalService.shared?.gate ?? ExternalGate(url: nil, prompter: nil)

  private var filteredSessions: [ComputerSession] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return store.sessions.filter {
      query.isEmpty || $0.computer.name.localizedCaseInsensitiveContains(query)
        || $0.computer.displayType.localizedCaseInsensitiveContains(query)
    }
  }

  /// Computers Noodle Hub keeps for its bots are listed apart from this Mac's own.
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
    } label: {
      Label("Create", systemImage: "plus")
    }.help("Create Computer")
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      List(selection: $store.selection) {
        let sections = ComputerExternalService.sections(filteredSessions,
          created: Set(external.grants.callers.flatMap { $0.resources.filter(\.created).map(\.id) }))
        Section("Computers") { rows(sections.own) }
        if !sections.external.isEmpty { Section("Agents") { rows(sections.external) } }
        let hub = ComputerStore.hubGroups(sections.hub)
        if !hub.people.isEmpty || !hub.unowned.isEmpty {
          Section("Hub") {
            ForEach(hub.people, id: \.owner.id) { group in
              DisclosureGroup(isExpanded: Binding(
                get: { !foldedPeople.contains(group.owner.id) },
                set: { if $0 { foldedPeople.remove(group.owner.id) } else { foldedPeople.insert(group.owner.id) } })
              ) { rows(group.sessions) } label: { Label(group.owner.name, systemImage: "person") }
            }
            rows(hub.unowned)
          }
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
    .sheet(isPresented: $showingWindows) {
      if #available(macOS 27, *) { NewWindowsView(store: store) }
    }
    .onReceive(NotificationCenter.default.publisher(for: .newComputer)) { _ in showingNew = true }
    .onReceive(NotificationCenter.default.publisher(for: .newLocalMac)) { _ in showingLocalMac = true }
    .onReceive(NotificationCenter.default.publisher(for: .newWindows)) { _ in
      if #available(macOS 27, *) { showingWindows = true }
    }
    .onChange(of: store.selection) { _, id in
      UserDefaults.standard.set(id?.uuidString, forKey: "SelectedComputer")
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
      if session.computer.kind == .container {
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
    .alert(session.computer.kind == .localMac ? "Delete \(session.computer.name) and its account?" : "Move \(session.computer.name) to Trash?", isPresented: $deleting) {
      Button("Cancel", role: .cancel) {}
      Button(session.computer.kind == .localMac ? "Delete Account" : "Move to Trash", role: .destructive) { store.remove(session) }
    } message: { Text(session.computer.kind == .localMac ? "This permanently deletes the managed account and its home directory. Stop preserves them; Delete removes them." : "The computer and its disks will be moved to the Trash.") }
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

struct ComputerDetailView: View {
  @ObservedObject var store: ComputerStore
  @ObservedObject var session: ComputerSession
  var sidebarCollapsed = false
  @State private var editing = false
  @State private var stopping = false

  var body: some View {
    Group {
      if session.phase == .updating {
        VStack(spacing: 16) {
          ProgressView(value: session.updateProgress).frame(width: 240)
          Text(session.updateStatus ?? "Upgrading the computer image…")
          Button("Cancel") { store.cancelImageUpdate(session) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if case .setupRequired(let registration) = session.phase {
        ContentUnavailableView {
          Label(registration.setupTitle, systemImage: "lock.shield")
        } description: {
          Text(LocalMacSetupRequired(registration: registration).localizedDescription)
        } actions: {
          Button(registration.setupActionTitle) {
            do { try LocalMacSetup.resolve(registration) } catch { store.error = error.localizedDescription }
          }
        }
      } else if let local = session.localMac {
        ZStack {
          LocalMacDesktopView(runtime: local, active: session.displayMode == .desktop, openSettings: { editing = true })
            .opacity(session.displayMode == .desktop ? 1 : 0)
            .allowsHitTesting(session.displayMode == .desktop)
            .accessibilityHidden(session.displayMode != .desktop)
          if session.showingFiles {
            ComputerFilesView(model: session.filesModel(for: local), appearance: session.computer.appearance ?? .init()).id(session.id)
          } else if session.showingTerminal, let terminal = session.terminal {
            ComputerTerminalView(terminal: terminal, appearance: session.computer.appearance ?? .init())
          }
        }
        // Restart polling, native surfaces and the file view's StateObject when
        // Start replaces a failed Local Mac connection for the same computer.
        .id(ObjectIdentifier(local))
      } else if let runtime = session.windowsRuntime {
        if #available(macOS 27, *), let windows = runtime as? WindowsComputer {
          ZStack {
            WindowsDisplay(computer: windows)
              .opacity(session.displayMode == .desktop ? 1 : 0)
              .allowsHitTesting(session.displayMode == .desktop)
              .accessibilityHidden(session.displayMode != .desktop)
            if session.showingFiles {
              ComputerFilesView(model: session.filesModel(for: windows), appearance: session.computer.appearance ?? .init()).id(session.id)
            } else if session.showingTerminal, let terminal = session.terminal {
              ComputerTerminalView(terminal: terminal, appearance: session.computer.appearance ?? .init())
            }
          }
          .id(ObjectIdentifier(windows))
        }
      } else if let virtual = session.virtual {
        VirtualMachineDisplay(machine: virtual.machine).ignoresSafeArea(edges: .top)
      } else if let machine = session.display?.machine {
        // Keep the guest's panel below the native toolbar, just like Shell.
        // Only the background may extend into the titlebar area.
        ZStack {
          // The VM runs without its view, and a hidden view would still set the pointer
          // for the Terminal or Files shown above it, so show it only for Desktop.
          if session.displayMode == .desktop {
            VirtualMachineDisplay(machine: machine, resizes: session.computer.resizesDesktop, native: session.display)
          }
          if session.showingFiles, session.phase == .running, let runtime = session.container {
            ComputerFilesView(model: session.filesModel(for: runtime), appearance: session.computer.appearance ?? .init()).id(session.id)
          } else if session.showingTerminal, let terminal = session.terminal {
            ComputerTerminalView(terminal: terminal, appearance: session.computer.appearance ?? .init())
          }
        }
      } else if session.showingFiles, session.phase == .running, let runtime = session.container {
        ComputerFilesView(model: session.filesModel(for: runtime), appearance: session.computer.appearance ?? .init()).id(session.id)
      } else if let terminal = session.terminal {
        ComputerTerminalView(terminal: terminal, appearance: session.computer.appearance ?? .init())
      } else {
        ContentUnavailableView {
          Label(
            session.phase.busy ? session.phase.label : session.computer.name,
            systemImage: session.computer.displaySymbol)
        } description: {
          if let result = session.updateResult, session.phase == .stopped {
            Text(result)
          } else if case .failed(let message) = session.phase {
            Text(message)
          } else if session.computer.kind == .container && !session.computer.hasDesktop {
            Text(session.phase.busy ? "Opening the terminal…" : "Start this computer to open its terminal.")
          } else {
            Text(
              session.phase == .running
                ? "Connecting to the desktop…" : "Start this computer to open its screen.")
          }
        } actions: {
          if session.localMacSetupRequired {
            Button(session.localMacSetupStatus == .enabled ? "Repair Local Mac…" : "Open Local Mac Setup…") {
              do { try LocalMacSetup.enable() } catch { store.error = error.localizedDescription }
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task(id: session.id) { await session.refreshLocalMacSetup() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      Task { await session.refreshLocalMacSetup() }
    }
    .companionContentPanel(sidebarCollapsed: sidebarCollapsed)
    .toolbar {
      ToolbarItem(id: "computer-edit", placement: .primaryAction) {
        Button {
          editing = true
        } label: {
          Label("Edit Computer", systemImage: "ellipsis")
        }.help("Edit Computer")
      }
      ToolbarItem(id: "computer-power", placement: .primaryAction) {
          Button {
            if session.phase == .running {
              stopping = true
            } else {
              Task { await store.start(session) }
            }
          } label: {
            ComputerToolbarSymbol(systemName: session.phase == .running ? "power" : "play.fill",
                                  busy: session.phase.busy)
          }
          .disabled(session.phase.busy)
          .help(session.phase.busy ? session.phase.label : session.phase == .running ? "Stop" : "Start")
          .accessibilityLabel(session.phase.busy ? session.phase.label : session.phase == .running ? "Stop" : "Start")
      }
      if [.container, .localMac, .windows].contains(session.computer.kind) {
        ToolbarItem(id: "computer-display", placement: .primaryAction) {
          Picker("Computer View", selection: Binding(
            get: { session.displayMode },
            set: { mode in Task { await store.selectDisplay(mode, in: session) } }
          )) {
            ForEach(session.availableDisplayModes, id: \.self) { mode in
              Image(systemName: mode.symbol).tag(mode)
                .accessibilityLabel(mode.rawValue).help(mode.rawValue)
            }
          }
          .pickerStyle(.segmented).labelsHidden().fixedSize()
          .disabled(session.phase != .running || session.openingTerminal || session.waitingForWindows)
          .help(session.waitingForWindows ? "Terminal and Files open once Windows has signed in" : "")
          .accessibilityValue(session.displayMode.rawValue)
        }
      }
      if let local = session.localMac, session.displayMode == .desktop {
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(id: "computer-focus-window", placement: .primaryAction) {
          LocalMacFocusWindowButton(runtime: local, enabled: session.phase == .running)
        }
        ToolbarItem(id: "computer-all-windows", placement: .primaryAction) {
          LocalMacFocusWindowButton(runtime: local, enabled: session.phase == .running, all: true)
        }
      }
      // Files declares the item after its own, so it stays at the trailing edge.
      if !showsFiles { CompanionSettingsToolbarItem(spacing: .flexible) }
    }
    .sheet(isPresented: $editing) {
      EditComputerView(store: store, session: session)
    }
    .computerStopConfirmation(isPresented: $stopping, name: session.computer.name) {
      guard session.phase == .running else { return }
      Task { await store.stop(session) }
    }
  }

  /// Mirrors the branches above that show ComputerFilesView.
  private var showsFiles: Bool {
    guard session.showingFiles, session.phase != .updating else { return false }
    if case .setupRequired = session.phase { return false }
    if session.localMac != nil { return true }
    if session.windowsRuntime != nil { return session.phase == .running }
    return session.virtual == nil && session.phase == .running && session.container != nil
  }
}

/// Use the intrinsic label size of the sliders symbol, a full-height glyph. The hidden
/// reference keeps Start/Stop/progress stable without inflating the native bar.
struct ComputerToolbarSymbol: View {
  let systemName: String
  var busy = false
  var body: some View {
    Label("", systemImage: "slider.horizontal.3")
      .labelStyle(.iconOnly)
      .hidden()
      .overlay {
        if busy {
          ProgressView().controlSize(.mini)
        } else {
          Image(systemName: systemName)
        }
      }
      .accessibilityHidden(true)
  }
}

struct EditComputerView: View {
  @ObservedObject var store: ComputerStore
  @ObservedObject var session: ComputerSession
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var description = ""
  @State private var deleting = false
  @State private var forceStopping = false
  @State private var updating = false
  @State private var appearance = ComputerAppearance()
  @State private var resizesDesktop = false
  @State private var cpus = 0
  @State private var memory = 0
  @State private var network = true
  private var stopLabel: String { session.computer.usesVirtualMachine || session.computer.kind == .windows ? "Force Stop" : "Stop" }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).foregroundStyle(.blue)
        Spacer()
        Text("Edit Computer").font(.headline).foregroundStyle(.primary)
        Spacer()
        Button("Save") {
          store.rename(session, name: name, description: description, appearance: appearance,
                       resizesDesktop: session.computer.hasDesktop ? resizesDesktop : nil)
          let computer = session.computer
          if computer.kind != .localMac,
             (cpus, memory, network) != (computer.cpuCount, computer.memoryGiB, computer.networkEnabled) {
            do { try store.changeResources(session, cpus: cpus, memoryGiB: memory, networkEnabled: network) }
            catch { store.error = error.localizedDescription }
          }
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .foregroundStyle(.blue)
        .disabled(
          name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || name.count > 100 || name.contains(where: \.isNewline)
            || description.trimmingCharacters(in: .whitespacesAndNewlines).count > Computer.maximumDescriptionLength)
      }.buttonStyle(.plain).padding(20)
      Divider()
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            ComputerIconButton(appearance: $appearance, symbol: session.computer.displaySymbol)
            TextField("Name", text: $name).autocorrectionDisabled()
              .textFieldStyle(.roundedBorder).lineLimit(1)
          }
          TextField("Description", text: $description, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...3)
            .help("Tells assigned bots what this computer is for")
        }
        .padding(12)
        .background(Color.secondary.opacity(0.075), in: RoundedRectangle(cornerRadius: 12))
        VStack(alignment: .leading, spacing: 12) {
          LabeledContent("Type", value: session.computer.displayType)
          Divider()
          if session.computer.kind == .localMac {
            LabeledContent("Resources", value: "Shared with this Mac")
            Divider()
            LabeledContent("Files", value: "Retained in its own account")
          } else {
            let editable = session.canDelete
            Group {
              if editable {
                ComputerResourceRow("CPUs", value: $cpus,
                  range: 1...max(2, session.computer.cpuCount, min(32, ProcessInfo.processInfo.processorCount)))
                Divider()
                ComputerResourceRow("Memory", value: $memory, unit: "GB",
                  range: (session.computer.template?.minimumMemoryGiB ?? 1)...max(64, session.computer.memoryGiB))
              } else {
                LabeledContent("CPUs", value: String(session.computer.cpuCount))
                Divider()
                LabeledContent("Memory", value: "\(session.computer.memoryGiB) GB")
              }
              Divider()
              LabeledContent("Disk capacity", value: "\(session.computer.diskGiB) GB")
              Text("Disk space grows as the computer uses it, up to this capacity.")
                .font(.caption).foregroundStyle(.secondary)
              Divider()
              Toggle("Networking", isOn: $network).toggleStyle(.switch).controlSize(.small)
                .fixedSize().disabled(!editable)
              Text("Allows this computer to connect to the internet and your local network.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
              if !editable {
                Text("Stop the computer to change its resources.")
                  .font(.caption).foregroundStyle(.secondary)
              }
            }
          }
          if session.computer.hasDesktop {
            Divider()
            Toggle("Resize desktop with window", isOn: $resizesDesktop).toggleStyle(.switch)
              .controlSize(.small).fixedSize()
          }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.075), in: RoundedRectangle(cornerRadius: 12))
        if let local = session.localMac { LocalMacPermissionsSettings(runtime: local) }
        if let result = session.updateResult {
          Text(result).font(.caption).foregroundStyle(.secondary)
        } else if session.imageUpdateAvailable && session.phase != .updating {
          Text("A newer image is available.").font(.caption).foregroundStyle(.orange)
        }
        if session.phase == .updating {
          Button("Cancel Upgrade") { store.cancelImageUpdate(session) }
          ProgressView(value: session.updateProgress)
          Text(session.updateStatus ?? "Upgrading…").font(.caption).foregroundStyle(.secondary)
        }
        ComputerAppearanceRow(appearance: $appearance, directory: store.library.directory(for: session.id))
        if session.computer.usesVirtualMachine && !session.computer.installationComplete && session.phase == .stopped {
          Button("Installation Finished — Eject ISO") { store.finishInstallation(session) }
        }
        Divider()
        HStack {
          DestructiveActionButton(title: "Delete Computer") { deleting = true }
            .disabled(!session.canDelete)
          Spacer()
          if session.computer.kind == .container {
            ComputerImageUpdateButton(session: session) { updating = true }
          }
          if session.virtual != nil || session.container != nil || session.localMac != nil || session.windowsRuntime != nil {
            Button(stopLabel) { forceStopping = true }.disabled(session.phase.busy)
          }
        }
      }.padding(20)
    }
    .frame(width: 580).noodleSheetSizing()
    .computerImageUpdateConfirmation(store: store, session: session, isPresented: $updating)
    .onAppear {
      name = session.computer.name; description = session.computer.description ?? ""
      appearance = session.computer.appearance ?? .init()
      resizesDesktop = session.computer.resizesDesktop
      cpus = session.computer.cpuCount; memory = session.computer.memoryGiB
      network = session.computer.networkEnabled
    }
    .alert(session.computer.kind == .localMac ? "Delete \(session.computer.name) and its account?" : "Move \(session.computer.name) to Trash?", isPresented: $deleting) {
      Button("Cancel", role: .cancel) {}
      Button(session.computer.kind == .localMac ? "Delete Account" : "Move to Trash", role: .destructive) {
        store.remove(session)
        dismiss()
      }
    } message: {
      Text(session.computer.kind == .localMac ? "This permanently deletes the managed account and its home directory. Stop preserves them; Delete removes them." : "The computer and its disks will be moved to the Trash.")
    }
    .computerStopConfirmation(isPresented: $forceStopping, name: session.computer.name, actionTitle: stopLabel) {
      guard !session.phase.busy, session.virtual != nil || session.container != nil || session.localMac != nil
        || session.windowsRuntime != nil else { return }
      Task { await store.stop(session, force: true) }
    }
  }
}

extension View {
  func computerStopConfirmation(
    isPresented: Binding<Bool>, name: String, actionTitle: String = "Stop",
    onConfirm: @escaping () -> Void
  ) -> some View {
    alert("\(actionTitle) \(name)?", isPresented: isPresented) {
      Button("Cancel", role: .cancel) {}
      Button(actionTitle, role: .destructive, action: onConfirm)
    } message: {
      Text("This will end the computer’s running processes. Unsaved work may be lost.")
    }
  }
}

struct VirtualMachineDisplay: NSViewRepresentable {
  let machine: VZVirtualMachine
  var resizes = true
  /// A Linux desktop: its size follows the setting at once, and ⌘C and ⌘V use the Mac clipboard.
  var native: NativeDisplay?
  func makeNSView(context: Context) -> VZVirtualMachineView {
    let view = DesktopMachineView()
    view.virtualMachine = machine
    view.capturesSystemKeys = true
    view.native = native
    updateNSView(view, context: context)
    return view
  }
  func updateNSView(_ view: VZVirtualMachineView, context: Context) {
    if view.virtualMachine !== machine { view.virtualMachine = machine }
    view.automaticallyReconfiguresDisplay = resizes
    (view as? DesktopMachineView)?.native = native
    let scale = view.window?.backingScaleFactor ?? 2
    native?.apply(resizes: resizes, viewPixels: CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale))
  }
}

/// The desktop's own view, which turns ⌘C and ⌘V, and Copy and Paste in the Edit menu,
/// into copy and paste between the Mac and the guest. The guest sees the Mac clipboard
/// only when someone pastes it.
final class DesktopMachineView: VZVirtualMachineView {
  var native: NativeDisplay?
  var pasteboard = NSPasteboard.general

  // The Edit menu, and its ⌘C and ⌘V, reach the focused view as these actions.
  @objc func copy(_ sender: Any?) { transfer(copying: true) }
  @objc func paste(_ sender: Any?) { transfer(copying: false) }

  // Without a menu item the keys arrive here, where the guest would otherwise get them.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard let copying = clipboardKey(event) else { return super.performKeyEquivalent(with: event) }
    transfer(copying: copying)
    return true
  }

  override func keyDown(with event: NSEvent) {
    guard let copying = clipboardKey(event) else { return super.keyDown(with: event) }
    transfer(copying: copying)
  }

  private func clipboardKey(_ event: NSEvent) -> Bool? {
    guard native != nil, event.type == .keyDown,
          event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return nil }
    switch event.charactersIgnoringModifiers?.lowercased() {
    case "c": return true
    case "v": return false
    default: return nil
    }
  }

  private func transfer(copying: Bool) {
    guard let native else { return }
    let pasteboard = pasteboard
    Task { @MainActor in
      if !copying {
        guard let text = pasteboard.string(forType: .string) else { return }
        try? await native.surface.paste(text)
      } else if let text = try? await native.surface.copy(), !text.isEmpty {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
      }
    }
  }
}

struct NewComputerView: View {
  @ObservedObject var store: ComputerStore
  @Environment(\.dismiss) private var dismiss
  @AppStorage("StartNewComputersAutomatically") private var startNewComputersAutomatically = true
  @State private var template: ComputerTemplate
  @State private var name: String
  @State private var cpus: Int
  @State private var memory: Int
  @State private var disk: Int
  @State private var advanced = false
  @State private var network = true
  @State private var resizesDesktop = false
  @State private var failure: String?
  @State private var appearance = ComputerAppearance()
  init(store: ComputerStore) {
    self.store = store
    let initialTemplate = ContainerRegistry.bundled.defaultTemplate
    _template = State(initialValue: initialTemplate)
    _name = State(initialValue: initialTemplate.defaultName)
    _cpus = State(initialValue: initialTemplate.defaultCPUs)
    _memory = State(initialValue: initialTemplate.defaultMemoryGiB)
    _disk = State(initialValue: initialTemplate.defaultDiskGiB)
  }
  private var draft: Computer {
    var computer = template.makeComputer(name: name)
    computer.cpuCount = cpus
    computer.memoryGiB = memory
    computer.diskGiB = disk
    computer.networkEnabled = network
    if template.type == .desktop { computer.resizesDesktopWithWindow = resizesDesktop }
    computer.appearance = appearance
    return computer
  }
  private var creating: Bool { store.creationStatus != nil }
  private var canCreate: Bool { !creating && (try? draft.validate()) != nil }
  var body: some View {
    Group {
      if creating {
        ComputerCreationProgressView(store: store)
      } else {
        VStack(spacing: 0) {
          HStack {
            Button("Cancel") { dismiss() }.disabled(creating).keyboardShortcut(.cancelAction)
              .buttonStyle(.plain).foregroundStyle(.blue)
            Spacer()
            Text("New Linux Container").font(.headline)
            Spacer()
            Button("Create") {
              Task {
                let computer = draft
                if await store.create(computer, source: nil) {
                  dismiss()
                  if startNewComputersAutomatically,
                    let session = store.sessions.first(where: { $0.id == computer.id })
                  {
                    await store.start(session)
                  }
                } else {
                  failure = store.creationWasCancelled ? nil : store.error
                  store.error = nil
                }
              }
            }.buttonStyle(.plain).foregroundStyle(canCreate ? Color.blue : .secondary)
              .keyboardShortcut(.defaultAction).disabled(!canCreate)
          }.padding(20)
          Divider()
          VStack(alignment: .leading, spacing: 16) {
            ComputerChoicePicker(selection: $template)
            VStack(alignment: .leading, spacing: 12) {
              HStack {
                ComputerIconButton(appearance: $appearance, symbol: template.symbol)
                TextField("Name", text: $name).autocorrectionDisabled()
                  .textFieldStyle(.roundedBorder).lineLimit(1)
              }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.075), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 12) {
              DisclosureGroup("Advanced Options", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 12) {
                  ComputerResourceRow("CPUs", value: $cpus,
                    range: 1...max(2, min(32, ProcessInfo.processInfo.processorCount)))
                  Divider()
                  ComputerResourceRow("Memory", value: $memory, unit: "GB",
                    range: template.minimumMemoryGiB...64)
                  Divider()
                  ComputerResourceRow("Disk capacity", value: $disk, unit: "GB",
                    range: template.minimumDiskGiB...512, step: 4)
                  Text("Disk space grows as the computer uses it, up to this capacity.").font(
                    .caption
                  )
                  .foregroundStyle(.secondary)
                  Divider()
                  Toggle("Networking", isOn: $network).toggleStyle(.switch).controlSize(.small)
                    .fixedSize()
                  Text(
                    "Allows this computer to connect to the internet and your local network."
                  )
                  .font(.caption).foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
                  if template.type == .desktop {
                    Divider()
                    Toggle("Resize desktop with window", isOn: $resizesDesktop).toggleStyle(.switch)
                      .controlSize(.small).fixedSize()
                  }
                }.padding(.top, 12)
              }.disclosureGroupStyle(ComputerDisclosureStyle())
            }
            .padding(12)
            .background(Color.secondary.opacity(0.075), in: RoundedRectangle(cornerRadius: 12))
            ComputerAppearanceRow(appearance: $appearance)
            if let failure {
              Text(failure).foregroundStyle(.red).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
          }.padding(20).disabled(creating)
        }
        .frame(width: 580)
      }
    }
    .noodleSheetSizing()
    .interactiveDismissDisabled(creating)
    .onChange(of: template) { oldValue, value in
      failure = nil
      if name == oldValue.defaultName { name = value.defaultName }
      cpus = value.defaultCPUs
      disk = value.defaultDiskGiB
      memory = value.defaultMemoryGiB
    }
  }
}

/// A Windows 11 computer. The first one downloads and installs Windows; later ones start from that install.
@available(macOS 27, *)
struct NewWindowsView: View {
  @ObservedObject var store: ComputerStore
  @Environment(\.dismiss) private var dismiss
  @AppStorage("StartNewComputersAutomatically") private var startNewComputersAutomatically = true
  @State private var name = "Windows"
  @State private var cpus = min(4, max(2, ProcessInfo.processInfo.processorCount))
  @State private var memory = ProcessInfo.processInfo.physicalMemory >= 16 << 30 ? 8 : 4
  @State private var disk = 64
  @State private var network = true
  @State private var advanced = false
  @State private var failure: String?
  @State private var appearance = ComputerAppearance()
  private var draft: Computer {
    var computer = Computer(name: name, kind: .windows, cpuCount: cpus, memoryGiB: memory, diskGiB: disk, networkEnabled: network)
    computer.appearance = appearance
    return computer
  }
  private var creating: Bool { store.creationStatus != nil }
  private var canCreate: Bool { !creating && (try? draft.validate()) != nil }
  var body: some View {
    Group {
      if creating {
        ComputerCreationProgressView(store: store)
      } else {
        VStack(spacing: 0) {
          HStack {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
              .buttonStyle(.plain).foregroundStyle(.blue)
            Spacer()
            Text("New Windows").font(.headline)
            Spacer()
            Button("Create") {
              Task {
                let computer = draft
                if await store.create(computer, source: nil) {
                  dismiss()
                  if startNewComputersAutomatically, let session = store.sessions.first(where: { $0.id == computer.id }) {
                    await store.start(session)
                  }
                } else {
                  failure = store.creationWasCancelled ? nil : store.error
                  store.error = nil
                }
              }
            }.buttonStyle(.plain).foregroundStyle(canCreate ? Color.blue : .secondary)
              .keyboardShortcut(.defaultAction).disabled(!canCreate)
          }.padding(20)
          Divider()
          VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
              Image(systemName: ComputerKind.windows.symbol).font(.system(size: 20)).foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)
              Text(ComputerKind.windows.detail).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.075), in: RoundedRectangle(cornerRadius: 12))
            HStack {
              ComputerIconButton(appearance: $appearance, symbol: ComputerKind.windows.symbol)
              TextField("Name", text: $name).autocorrectionDisabled().textFieldStyle(.roundedBorder).lineLimit(1)
            }
            .padding(12)
            .background(Color.secondary.opacity(0.075), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 12) {
              DisclosureGroup("Advanced Options", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 12) {
                  ComputerResourceRow("CPUs", value: $cpus, range: 2...max(2, min(32, ProcessInfo.processInfo.processorCount)))
                  Divider()
                  ComputerResourceRow("Memory", value: $memory, unit: "GB", range: 4...64)
                  Divider()
                  ComputerResourceRow("Disk capacity", value: $disk, unit: "GB", range: 64...512, step: 4)
                  Text("Disk space grows as the computer uses it, up to this capacity.").font(.caption).foregroundStyle(.secondary)
                  Divider()
                  Toggle("Networking", isOn: $network).toggleStyle(.switch).controlSize(.small).fixedSize()
                  Text("Allows this computer to connect to the internet and your local network.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 12)
              }.disclosureGroupStyle(ComputerDisclosureStyle())
            }
            .padding(12)
            .background(Color.secondary.opacity(0.075), in: RoundedRectangle(cornerRadius: 12))
            if let failure {
              Text(failure).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
          }.padding(20)
        }
        .frame(width: 580)
      }
    }
    .noodleSheetSizing()
    .interactiveDismissDisabled(creating)
  }
}

/// Present the computers people can create directly, using the registry's choices.
struct ComputerChoicePicker: View {
  @Binding var selection: ComputerTemplate

  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
      ForEach(ContainerRegistry.bundled.templates) { option in
        let selected = selection.id == option.id
        Button {
          selection = option
        } label: {
          VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
              Image(systemName: option.symbol)
                .font(.system(size: 20)).foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)
              Text(option.name).font(.headline)
              Spacer(minLength: 0)
              Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            Text(option.description).font(.callout).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
          .padding(14)
          .background(selected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.075),
            in: RoundedRectangle(cornerRadius: 12))
          .overlay {
            RoundedRectangle(cornerRadius: 12)
              .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.15),
                lineWidth: selected ? 1.5 : 1)
          }
          .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(option.name)
        .accessibilityHint(option.description)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityIdentifier("computer-choice-\(option.id)")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Computer type")
  }
}

/// Make the label, chevron and empty space one keyboard-accessible disclosure.
struct ComputerDisclosureStyle: DisclosureGroupStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
          configuration.isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
            .frame(width: 10).accessibilityHidden(true)
          configuration.label
          Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("computer-advanced-options")
      .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
      configuration.content
        .fixedSize(horizontal: false, vertical: true)
        .frame(height: configuration.isExpanded ? nil : 0, alignment: .top)
        .clipped()
        .opacity(configuration.isExpanded ? 1 : 0)
        .disabled(!configuration.isExpanded)
        .allowsHitTesting(configuration.isExpanded)
        .accessibilityHidden(!configuration.isExpanded)
    }
  }
}

private struct ComputerResourceRow: View {
  let title: String
  @Binding var value: Int
  let unit: String
  let range: ClosedRange<Int>
  let step: Int

  init(_ title: String, value: Binding<Int>, unit: String = "", range: ClosedRange<Int>, step: Int = 1) {
    self.title = title; self._value = value; self.unit = unit; self.range = range; self.step = step
  }
  private var boundedValue: Binding<Int> {
    Binding(get: { value }, set: { value = min(range.upperBound, max(range.lowerBound, $0)) })
  }
  var body: some View {
    HStack(spacing: 8) {
      Text(title)
      Spacer()
      TextField(title, value: boundedValue, format: .number.grouping(.never))
        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
        .monospacedDigit().frame(width: 64)
        .accessibilityLabel(unit.isEmpty ? title : "\(title) in \(unit)")
      Text(unit).foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
      Stepper(title, value: boundedValue, in: range, step: step).labelsHidden()
        .fixedSize().accessibilityLabel("Adjust \(title)")
    }
  }
}

struct ComputerCreationProgressView: View {
  @ObservedObject var store: ComputerStore
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 14) {
        Image(systemName: "desktopcomputer").font(.system(size: 32)).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 5) {
          Text("Creating \(store.creationName)").font(.headline).lineLimit(1)
          Text(
            store.creationCancelling
              ? "Cancelling and cleaning up…" : (store.creationStatus ?? "Preparing…")
          )
          .foregroundStyle(.secondary)
        }
      }
      VStack(alignment: .leading, spacing: 8) {
        ProgressView(value: store.creationProgress).progressViewStyle(.linear)
          // Recreate AppKit's indicator when moving from unknown to
          // known length; otherwise its indeterminate animation lingers.
          .id(store.creationProgress != nil)
          .accessibilityLabel(store.creationStatus ?? "Creation progress")
        if store.creationDetail != nil || store.creationProgress != nil {
          HStack {
            if let detail = store.creationDetail { Text(detail).monospacedDigit() }
            Spacer()
            if let progress = store.creationProgress {
              Text(progress, format: .percent.precision(.fractionLength(0))).monospacedDigit()
            }
          }.font(.caption).foregroundStyle(.secondary)
        }
      }
      HStack {
        TimelineView(.periodic(from: .now, by: 1)) { context in
          let seconds = max(0, Int(context.date.timeIntervalSince(store.creationStartedAt)))
          Text("Elapsed \(String(format: "%d:%02d", seconds / 60, seconds % 60))")
            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        Spacer()
        Button(store.creationCancelling ? "Cancelling…" : "Cancel") { store.cancelCreation() }
          .keyboardShortcut(.cancelAction).disabled(store.creationCancelling)
          .buttonStyle(.plain).foregroundStyle(store.creationCancelling ? Color.secondary : .blue)
      }
    }
    .padding(24)
    .frame(width: 520)
    .interactiveDismissDisabled()
  }
}
