import AppKit
import ComputerCore
import SwiftUI
import UniformTypeIdentifiers
import Virtualization

@main
struct NoodleComputerApp: App {
  @NSApplicationDelegateAdaptor(ComputerAppDelegate.self) private var delegate
  var body: some Scene {
    Window("Noodle Computer", id: "library") {
      ComputerRootView()
        .frame(minWidth: 850, minHeight: 580)
    }
    .defaultLaunchBehavior(CommandLine.arguments.contains("--noodle-background") ? .suppressed : .automatic)
    .restorationBehavior(CommandLine.arguments.contains("--noodle-background") ? .disabled : .automatic)
    .defaultSize(width: 1080, height: 720)
    .windowToolbarStyle(.unified(showsTitle: false))
    .commands {
      CommandGroup(after: .appSettings) { ComputerCheckForUpdatesButton() }
      CommandGroup(replacing: .appInfo) {
        Button("About Noodle Computer") {
          NSApplication.shared.orderFrontStandardAboutPanel(options: [.applicationName: "Noodle Computer"])
        }
      }
      CommandGroup(replacing: .help) {
        Button("Noodle Computer Help") {
          NSWorkspace.shared.open(URL(string: "https://github.com/pdparchitect/noodle")!)
        }
      }
      CommandGroup(replacing: .newItem) {
        Button("New Computer…") { NotificationCenter.default.post(name: .newComputer, object: nil) }
          .keyboardShortcut("n")
        Button("New from Container Image…") { NotificationCenter.default.post(name: .newCustomComputer, object: nil) }
      }
    }
    Settings {
      ComputerSettingsView()
        .preferredColorScheme(.dark)
    }
    .windowResizability(.contentSize)
  }
}

extension Notification.Name {
  static let newComputer = Self("NoodleComputer.New")
  static let newCustomComputer = Self("NoodleComputer.NewCustom")
}

@MainActor final class ComputerAppDelegate: NSObject, NSApplicationDelegate {
  static var store: ComputerStore?
  func applicationDidBecomeActive(_ notification: Notification) {
    // Quiet agent-driven provider launches must not show update prompts.
    ComputerUpdater.shared.start()
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    guard CommandLine.arguments.contains("--noodle-background") else { return }
    // Also cover Launch Services reopening a previously registered single-window
    // app. This affects only this process; an explicit later open unhides it.
    NSApp.hide(nil)
    if CommandLine.arguments.contains("--provider-integration-test") {
      Task {
        do { try await ComputerSmokeTest.checkProvider(); NSApp.terminate(nil) }
        catch { fputs("PROVIDER TEST FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
      }
      return
    }
    // The provider can own the library without creating a SwiftUI window.
    do { _ = try Self.loadLibrary() }
    catch { fputs("Computer provider: \(error.localizedDescription)\n", stderr) }
  }
  static func loadLibrary() throws -> ComputerStore {
    if let store { return store }
    let model = try ComputerStore()
    model.provider = try ComputerProvider(store: model)
    store = model
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
    Task {
      try? await Task.sleep(for: .seconds(10))
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
      } else {
        ProgressView("Opening computer library…")
      }
    }
    .task {
      guard store == nil, startupError == nil else { return }
      do {
        if CommandLine.arguments.contains("--updater-ui-test") {
          try await ComputerSmokeTest.checkUpdaterUI()
          if !CommandLine.arguments.contains("--keep-test-window") { NSApplication.shared.terminate(nil) }
          return
        }
        if CommandLine.arguments.contains("--noodle-background") {
          // The delegate hides the initial background launch. Do not hide here:
          // this view may first be created by a later explicit Open from Noodle.
          // Launch restoration must never run a second provider/fixture through
          // the view. The app delegate owns background initialization.
          guard !CommandLine.arguments.contains("--provider-integration-test") else { return }
          store = try ComputerAppDelegate.loadLibrary()
          return
        }
        if CommandLine.arguments.contains("--provider-integration-test") {
          try await ComputerSmokeTest.checkProvider()
          NSApplication.shared.terminate(nil)
          return
        }
        if CommandLine.arguments.contains("--library-layout-test") {
          try await ComputerSmokeTest.checkLibraryLayout()
          NSApplication.shared.terminate(nil)
          return
        }
        if CommandLine.arguments.contains("--empty-library-test") {
          try await ComputerSmokeTest.checkEmptyLibraryBackground()
          NSApplication.shared.terminate(nil)
          return
        }
        if CommandLine.arguments.contains("--appearance-preview") {
          try await ComputerSmokeTest.checkAppearancePreview()
          NSApplication.shared.terminate(nil)
          return
        }
        if CommandLine.arguments.contains("--custom-container-test") {
          try await ComputerSmokeTest.checkCustomContainer()
          NSApplication.shared.terminate(nil)
          return
        }
        if CommandLine.arguments.contains("--creation-form-test") {
          try await ComputerSmokeTest.checkCreationForm()
          NSApplication.shared.terminate(nil)
          return
        }
        if CommandLine.arguments.contains("--desktop-smoke-test") {
          try await ComputerSmokeTest.checkDesktop()
          NSApplication.shared.terminate(nil)
          return
        }
        if CommandLine.arguments.contains("--download-progress-test") {
          try await ComputerSmokeTest.checkDownloadProgressAndCancellation()
          NSApplication.shared.terminate(nil)
          return
        }
        if CommandLine.arguments.contains("--linux-boot-test") {
          let model = try await ComputerSmokeTest.linuxBootFixture()
          store = model
          ComputerAppDelegate.store = model
          return
        }
        if CommandLine.arguments.contains("--configuration-test") {
          try await ComputerSmokeTest.checkMacConfiguration()
          NSApplication.shared.terminate(nil)
          return
        }
        if CommandLine.arguments.contains("--self-test") {
          try await ComputerSmokeTest.run(
            networkEnabled: !CommandLine.arguments.contains("--offline"))
          NSApplication.shared.terminate(nil)
          return
        }
        let model = try ComputerAppDelegate.loadLibrary()
        store = model
      } catch {
        startupError = error.localizedDescription
        if CommandLine.arguments.contains("--custom-container-test")
          || CommandLine.arguments.contains("--updater-ui-test")
          || CommandLine.arguments.contains("--empty-library-test")
          || CommandLine.arguments.contains("--library-layout-test")
          || CommandLine.arguments.contains("--provider-integration-test")
          || CommandLine.arguments.contains("--creation-form-test")
          || CommandLine.arguments.contains("--desktop-smoke-test")
          || CommandLine.arguments.contains("--self-test")
          || CommandLine.arguments.contains("--configuration-test")
          || CommandLine.arguments.contains("--download-progress-test")
        {
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
  @State private var showingCustom = false
  @State private var searchText = ""
  @State private var columnVisibility = NavigationSplitViewVisibility.all
  @AppStorage("ComputerSidebarVisible") private var sidebarVisible = true

  private var filteredSessions: [ComputerSession] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return store.sessions.filter {
      query.isEmpty || $0.computer.name.localizedCaseInsensitiveContains(query)
        || $0.computer.displayType.localizedCaseInsensitiveContains(query)
    }
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      List(selection: $store.selection) {
        Section("Computers") {
          ForEach(filteredSessions) { session in
            ComputerRow(store: store, session: session).tag(session.id)
          }
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .background(Color.black.opacity(0.24).ignoresSafeArea())
      .searchable(text: $searchText, placement: .sidebar, prompt: "Search")
      .controlSize(.large)
      .navigationSplitViewColumnWidth(min: 280, ideal: 326, max: 380)
      .overlay {
        if !store.sessions.isEmpty && filteredSessions.isEmpty {
          ContentUnavailableView.search(text: searchText)
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
          Text("Create a Desktop or Shell computer.")
        } actions: {
          Button("Create a Computer…") { showingNew = true }
        }
      }
    }
    .navigationSplitViewStyle(.balanced)
    .background {
      if let session = store.selected {
        ComputerWindowWallpaper(session: session).ignoresSafeArea()
      } else {
        // The compositing window is clear even without a selected computer.
        // Keep the library opaque using the same base as a default wallpaper.
        ComputerWallpaper(appearance: ComputerAppearance()).ignoresSafeArea()
      }
    }
    .background(ComputerWindowCompositing())
    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    .toolbar {
      ToolbarItem(placement: .navigation) {
        Menu {
          Button("New Computer", systemImage: "desktopcomputer") { showingNew = true }
            .keyboardShortcut("n", modifiers: .command)
          Button("New from Container Image…", systemImage: "shippingbox") { showingCustom = true }
        } label: {
          Label("Create", systemImage: "square.and.pencil")
        }.help("Create Computer")
      }
    }
    .onAppear { columnVisibility = sidebarVisible ? .all : .detailOnly }
    .onChange(of: columnVisibility) { _, value in sidebarVisible = value != .detailOnly }
    .sheet(isPresented: $showingNew) { NewComputerView(store: store) }
    .sheet(isPresented: $showingCustom) { NewComputerView(store: store, custom: true) }
    .onReceive(NotificationCenter.default.publisher(for: .newComputer)) { _ in showingNew = true }
    .onReceive(NotificationCenter.default.publisher(for: .newCustomComputer)) { _ in showingCustom = true }
    .onChange(of: store.selection) { _, id in
      UserDefaults.standard.set(id?.uuidString, forKey: "SelectedComputer")
    }
    .alert(
      "Noodle Computer",
      isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })
    ) {
      Button("OK") { store.error = nil }
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
      Button(session.phase == .running ? "Stop…" : "Start", systemImage: session.phase == .running ? "power" : "play.fill") {
        if session.phase == .running { stopping = true }
        else { Task { await store.start(session) } }
      }.disabled(session.phase.busy)
      Divider()
      Button("Delete Computer…", systemImage: "trash", role: .destructive) { deleting = true }
        .disabled(session.phase != .stopped || session.virtual != nil || session.container != nil)
    }
    .sheet(isPresented: $editing) { EditComputerView(store: store, session: session) }
    .sheet(isPresented: $changingBackground) {
      ComputerAppearanceSheet(appearance: Binding(
        get: { session.computer.appearance ?? .init() },
        set: { store.rename(session, name: session.computer.name, appearance: $0) }))
    }
    .alert("Move \(session.computer.name) to Trash?", isPresented: $deleting) {
      Button("Cancel", role: .cancel) {}
      Button("Move to Trash", role: .destructive) { store.remove(session) }
    } message: { Text("The computer and its disks will be moved to the Trash.") }
    .computerStopConfirmation(isPresented: $stopping, name: session.computer.name) {
      guard session.phase == .running else { return }
      Task { await store.stop(session) }
    }
  }

  private var statusColor: Color {
    switch session.phase {
    case .running: .green
    case .starting, .stopping: .orange
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
      if let virtual = session.virtual {
        VirtualMachineDisplay(machine: virtual.machine).ignoresSafeArea(edges: .top)
      } else if let browser = session.browser {
        // Keep the guest's panel below the native toolbar, just like Shell.
        // Only the background may extend into the titlebar area.
        ZStack {
          // Retain the desktop connection while the recovery terminal is shown.
          ComputerDesktopView(browser: browser)
            .opacity(session.showingTerminal ? 0 : 1)
            .allowsHitTesting(!session.showingTerminal)
            .accessibilityHidden(session.showingTerminal)
          if session.showingTerminal, let terminal = session.terminal {
            ComputerTerminalView(terminal: terminal, appearance: session.computer.appearance ?? .init())
          }
        }
      } else if let terminal = session.terminal {
        ComputerTerminalView(terminal: terminal, appearance: session.computer.appearance ?? .init())
      } else {
        ContentUnavailableView {
          Label(
            session.phase.busy ? session.phase.label : session.computer.name,
            systemImage: session.computer.displaySymbol)
        } description: {
          if case .failed(let message) = session.phase {
            Text(message)
          } else if session.computer.kind == .container && !session.computer.hasDesktop {
            Text(session.phase.busy ? "Opening the terminal…" : "Start this computer to open its terminal.")
          } else {
            Text(
              session.phase == .running
                ? "Connecting to the desktop…" : "Start this computer to open its screen.")
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // Native sidebar glass paints inside a one-point edge. Match that visible
    // edge without changing the shared terminal/WebKit layout or hit area.
    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous).inset(by: 1))
    // Keep the inter-panel gap when expanded; match the outer inset when collapsed.
    .padding(.leading, sidebarCollapsed ? 8 : 12)
    // Match the native sidebar's outer window inset.
    .padding(.trailing, 8)
    // The native toolbar already leaves 8 points below its controls.
    .padding(.top, 4)
    // The clip adds one point, placing the visible bottom at the sidebar's 8-point inset.
    .padding(.bottom, 7)
    .toolbar {
      ToolbarItem(id: "computer-edit", placement: .primaryAction) {
        Button {
          editing = true
        } label: {
          Label("Edit Computer", systemImage: "slider.horizontal.3")
        }.help("Edit Computer")
      }
      ToolbarSpacer(.fixed, placement: .primaryAction)
      if session.computer.hasWebDisplay {
        ToolbarItem(id: "computer-display", placement: .primaryAction) {
          Button {
            Task { await store.toggleTerminal(session) }
          } label: {
            ComputerToolbarSymbol(systemName: session.showingTerminal ? "desktopcomputer" : "terminal")
          }
          .disabled(session.phase != .running || session.openingTerminal)
          .help(session.showingTerminal ? "Show Desktop" : "Show Terminal")
          .accessibilityLabel(session.showingTerminal ? "Show Desktop" : "Show Terminal")
        }
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
          .help(session.phase.busy ? session.phase.label : session.phase == .running ? "Stop…" : "Start")
          .accessibilityLabel(session.phase.busy ? session.phase.label : session.phase == .running ? "Stop…" : "Start")
      }
    }
    .sheet(isPresented: $editing) {
      EditComputerView(store: store, session: session)
    }
    .computerStopConfirmation(isPresented: $stopping, name: session.computer.name) {
      guard session.phase == .running else { return }
      Task { await store.stop(session) }
    }
  }
}

/// Use the same intrinsic label size as Noodle's edit toolbar item. The hidden
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
  @State private var deleting = false
  @State private var forceStopping = false
  @State private var appearance = ComputerAppearance()
  private var stopLabel: String { session.computer.kind == .container ? "Stop" : "Force Stop" }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).foregroundStyle(.blue)
        Spacer()
        Text("Edit Computer").font(.headline).foregroundStyle(.primary)
        Spacer()
        Button("Save") {
          store.rename(session, name: name, appearance: appearance)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .foregroundStyle(.blue)
        .disabled(
          name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || name.count > 100 || name.contains(where: \.isNewline))
      }.buttonStyle(.plain).padding(20)
      Divider()
      VStack(alignment: .leading, spacing: 18) {
        HStack(spacing: 14) {
          ComputerIconButton(appearance: $appearance, symbol: session.computer.displaySymbol)
          TextField("Computer name", text: $name).textFieldStyle(.roundedBorder).lineLimit(1)
        }
        VStack(alignment: .leading, spacing: 12) {
          LabeledContent("Computer", value: session.computer.displayType)
          Divider()
          LabeledContent("CPUs", value: String(session.computer.cpuCount))
          LabeledContent("Memory", value: "\(session.computer.memoryGiB) GB")
          LabeledContent("Disk capacity", value: "\(session.computer.diskGiB) GB")
        }.padding(12).background(
          Color.secondary.opacity(0.075), in: RoundedRectangle(cornerRadius: 12))
        ComputerAppearanceRow(appearance: $appearance)
        if !session.computer.installationComplete && session.phase == .stopped {
          Button("Installation Finished — Eject ISO") { store.finishInstallation(session) }
        }
        Divider()
        HStack {
          DestructiveActionButton(title: "Delete Computer") { deleting = true }
            .disabled(session.phase != .stopped || session.virtual != nil || session.container != nil)
          Spacer()
          if session.virtual != nil || session.container != nil {
            Button("\(stopLabel)…") { forceStopping = true }.disabled(session.phase.busy)
          }
        }
      }.padding(20)
    }
    .frame(width: 520).noodleSheetSizing()
    .onAppear { name = session.computer.name; appearance = session.computer.appearance ?? .init() }
    .alert("Move \(session.computer.name) to Trash?", isPresented: $deleting) {
      Button("Cancel", role: .cancel) {}
      Button("Move to Trash", role: .destructive) {
        store.remove(session)
        dismiss()
      }
    } message: {
      Text("The computer and its disks will be moved to the Trash.")
    }
    .computerStopConfirmation(isPresented: $forceStopping, name: session.computer.name, actionTitle: stopLabel) {
      guard !session.phase.busy, session.virtual != nil || session.container != nil else { return }
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
  func makeNSView(context: Context) -> VZVirtualMachineView {
    let view = VZVirtualMachineView()
    view.virtualMachine = machine
    view.capturesSystemKeys = true
    view.automaticallyReconfiguresDisplay = true
    return view
  }
  func updateNSView(_ view: VZVirtualMachineView, context: Context) {
    if view.virtualMachine !== machine { view.virtualMachine = machine }
  }
}

struct NewComputerView: View {
  @ObservedObject var store: ComputerStore
  let custom: Bool
  @Environment(\.dismiss) private var dismiss
  @AppStorage("StartNewComputersAutomatically") private var startNewComputersAutomatically = true
  @State private var template = ComputerTemplate.desktop
  @State private var name = "My Desktop"
  @State private var cpus = 4
  @State private var memory = 4
  @State private var disk = 32
  @State private var advanced = false
  @State private var network = true
  @State private var failure: String?
  @State private var imageReference = ""
  @State private var webPort = ""
  @State private var appearance = ComputerAppearance()
  init(store: ComputerStore, custom: Bool = false) {
    self.store = store
    self.custom = custom
    _name = State(initialValue: custom ? "My Container" : "My Desktop")
    _cpus = State(initialValue: custom ? 2 : 4)
    _memory = State(initialValue: custom ? 1 : 4)
    _disk = State(initialValue: custom ? 8 : 32)
  }
  private var portText: String { webPort.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var requiresNetworking: Bool { custom ? !portText.isEmpty : template.requiresNetworking }
  private var draft: Computer {
    var computer = (custom ? ComputerTemplate.shell : template).makeComputer(name: name)
    computer.cpuCount = cpus
    computer.memoryGiB = memory
    computer.diskGiB = disk
    computer.networkEnabled = requiresNetworking || network
    computer.appearance = appearance
    if custom {
      computer.customImage = true
      computer.imageReference = imageReference.trimmingCharacters(in: .whitespacesAndNewlines)
      computer.webPort = Int(portText)
    }
    return computer
  }
  private var creating: Bool { store.creationStatus != nil }
  private var canCreate: Bool {
    !creating && (!custom || portText.isEmpty || Int(portText) != nil)
      && (try? draft.validate()) != nil
  }
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
            Text(custom ? "New from Container Image" : "New Computer").font(.headline)
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
            VStack(alignment: .leading, spacing: 12) {
              if custom {
                LabeledContent("Image") {
                  TextField("docker.io/library/nginx:alpine", text: $imageReference)
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                }
                LabeledContent("Web port") {
                  TextField("Optional", text: $webPort).textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                }
                Text("A public ARM64 Linux image with /bin/sh. Leave the web port blank for a terminal, or enter the container’s HTTP port to show its web interface.")
                  .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
              } else {
                Picker("Template", selection: $template) {
                  ForEach(ComputerTemplate.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                  }
                }
                Text(template.detail).font(.callout).foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              Divider()
              HStack {
                ComputerIconButton(appearance: $appearance, symbol: custom ? "shippingbox" : template.symbol)
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
                    range: (custom ? 1 : template.minimumMemoryGiB)...64)
                  Divider()
                  ComputerResourceRow("Disk capacity", value: $disk, unit: "GB",
                    range: (custom ? 4 : template.minimumDiskGiB)...512, step: 4)
                  Text("Disk space grows as the computer uses it, up to this capacity.").font(
                    .caption
                  )
                  .foregroundStyle(.secondary)
                  Divider()
                  Toggle("Networking", isOn: $network).toggleStyle(.switch).controlSize(.small)
                    .disabled(requiresNetworking)
                  if requiresNetworking {
                    Text("Required to connect to the web display.").font(.caption).foregroundStyle(.secondary)
                  }
                  Text(
                    "NAT networking allows access to the internet and potentially your local network. Host folders, clipboard, microphone, and camera are not shared."
                  )
                  .font(.caption).foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
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
    .onChange(of: requiresNetworking) { _, required in if required { network = true } }
    .onChange(of: template) { oldValue, value in
      failure = nil
      if name == oldValue.defaultName { name = value.defaultName }
      cpus = value.defaultCPUs
      disk = value.defaultDiskGiB
      memory = value.defaultMemoryGiB
      if value.requiresNetworking { network = true }
    }
  }
}

/// Make the label, chevron and empty space one keyboard-accessible disclosure.
struct ComputerDisclosureStyle: DisclosureGroupStyle {
  func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        configuration.isExpanded.toggle()
      } label: {
        HStack(spacing: 6) {
          Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption.weight(.semibold)).frame(width: 10).accessibilityHidden(true)
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
      if configuration.isExpanded { configuration.content }
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
            if let detail = store.creationDetail { Text(detail) }
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
