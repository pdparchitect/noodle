import AppKit
import ComputerBridge
import ComputerCore
import ComputerEngine
import NoodleSettingsUI
import NoodleWallpaper
import SwiftUI
import UniformTypeIdentifiers
import Virtualization

// The views a computer is made, shown and changed in. Noodle Computer's library window uses them, and so do
// apps that host the engine and compile this file, as Rook does; keep it free of the app's own types.

extension View {
  /// The computers' errors as an alert, with the way to fix one when there is a way. Every app that runs them shows these.
  func computerErrorAlert(store: ComputerStore) -> some View { modifier(ComputerErrorAlert(store: store)) }
}

private struct ComputerErrorAlert: ViewModifier {
  @ObservedObject var store: ComputerStore

  func body(content: Content) -> some View {
    content.alert(
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

struct ComputerDetailView: View {
  @ObservedObject var store: ComputerStore
  @ObservedObject var session: ComputerSession
  var sidebarCollapsed = false
  /// One opacity for every computer's terminal and files, set by an app that offers no appearance settings, as Rook.
  var panelOpacity: Double? = nil
  @State private var editing = false
  @State private var stopping = false

  private var appearance: ComputerAppearance { Self.panelAppearance(session.computer.appearance, opacity: panelOpacity) }

  static func panelAppearance(_ stored: ComputerAppearance?, opacity: Double?) -> ComputerAppearance {
    var appearance = stored ?? .init()
    if let opacity { appearance.terminalOpacity = opacity }
    return appearance
  }

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
            ComputerFilesView(model: session.filesModel(for: local), appearance: appearance).id(session.id)
          } else if session.showingTerminal, let terminal = session.terminal {
            ComputerTerminalView(terminal: terminal, appearance: appearance)
          }
        }
        // Restart polling, native surfaces and the file view's StateObject when
        // Start replaces a failed Local Mac connection for the same computer.
        .id(ObjectIdentifier(local))
      } else if let ssh = session.sshRuntime {
        Group {
          if session.showingFiles {
            ComputerFilesView(model: session.filesModel(for: ssh), appearance: appearance).id(session.id)
          } else if let terminal = session.terminal {
            ComputerTerminalView(terminal: terminal, appearance: appearance)
          }
        }
        .id(ObjectIdentifier(ssh))
      } else if let runtime = session.windowsRuntime {
        if #available(macOS 27, *), let windows = runtime as? WindowsComputer {
          ZStack {
            WindowsDisplay(computer: windows)
              .opacity(session.displayMode == .desktop ? 1 : 0)
              .allowsHitTesting(session.displayMode == .desktop)
              .accessibilityHidden(session.displayMode != .desktop)
            if session.showingFiles {
              ComputerFilesView(model: session.filesModel(for: windows), appearance: appearance).id(session.id)
            } else if session.showingTerminal, let terminal = session.terminal {
              ComputerTerminalView(terminal: terminal, appearance: appearance)
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
            if #available(macOS 27, *), let gpu = session.display?.virgl, let queue = session.display?.machineQueue {
              VirglDisplay(gpu: gpu, machine: machine, queue: queue, resizes: session.computer.resizesDesktop, native: session.display)
            } else {
              VirtualMachineDisplay(machine: machine, resizes: session.computer.resizesDesktop, native: session.display)
            }
          }
          if session.showingFiles, session.phase == .running, let runtime = session.container {
            ComputerFilesView(model: session.filesModel(for: runtime), appearance: appearance).id(session.id)
          } else if session.showingTerminal, let terminal = session.terminal {
            ComputerTerminalView(terminal: terminal, appearance: appearance)
          }
        }
      } else if session.showingFiles, session.phase == .running, let runtime = session.container {
        ComputerFilesView(model: session.filesModel(for: runtime), appearance: appearance).id(session.id)
      } else if let terminal = session.terminal {
        ComputerTerminalView(terminal: terminal, appearance: appearance)
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
          } else if session.computer.kind == .ssh {
            if let notice = session.sshNotice, session.phase == .starting {
              Text(ComputerNotice.linked(notice)).textSelection(.enabled)
            } else {
              Text(session.phase.busy ? "Connecting…" : "Start this computer to connect.")
            }
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
          Label("Edit Computer", systemImage: "pencil")
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
      if [.container, .localMac, .windows, .ssh].contains(session.computer.kind) {
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
    if session.windowsRuntime != nil || session.sshRuntime != nil { return session.phase == .running }
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
  @State private var disk = 0
  @State private var network = true
  @State private var changingSignIn = false
  private var stopLabel: String { session.computer.usesVirtualMachine || session.computer.kind == .windows ? "Force Stop" : "Stop" }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).foregroundStyle(Color.accentColor)
        Spacer()
        Text("Edit Computer").font(.headline).foregroundStyle(.primary)
        Spacer()
        Button("Save") {
          store.rename(session, name: name, description: description, appearance: appearance,
                       resizesDesktop: session.computer.resizesWithWindow ? resizesDesktop : nil)
          let computer = session.computer
          if computer.kind.capabilities.resourceEditing,
             (cpus, memory, disk, network) != (computer.cpuCount, computer.memoryGiB, computer.diskGiB, computer.networkEnabled) {
            do { try store.changeResources(session, cpus: cpus, memoryGiB: memory, diskGiB: disk, networkEnabled: network) }
            catch { store.error = error.localizedDescription }
          }
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .foregroundStyle(Color.accentColor)
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
          if let ssh = session.computer.ssh {
            LabeledContent("Address", value: ssh.address).textSelection(.enabled)
            Divider()
            LabeledContent("Sign In") {
              HStack {
                Text(ssh.credential == .key ? "Key" : ssh.credential == .password ? "Password" : "No key or password")
                Button("Change…") { changingSignIn = true }
              }
            }
            if ssh.hostKey != nil {
              Divider()
              LabeledContent("Server Key") {
                Button("Forget Server Key") { store.forgetServerKey(session) }
                  .help("Trust the key the server presents the next time it connects")
              }
            }
          } else if session.computer.kind == .localMac {
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
              if editable && session.computer.kind.capabilities.diskGrowth {
                ComputerResourceRow("Disk capacity", value: $disk, unit: "GB",
                  range: session.computer.diskGiB...max(512, session.computer.diskGiB), step: 4)
                  .help("Can grow but not shrink. Windows uses the new space when it next starts.")
              } else {
                LabeledContent("Disk capacity", value: "\(session.computer.diskGiB) GB")
              }
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
          if session.computer.resizesWithWindow {
            Divider()
            Toggle("Resize desktop with window", isOn: $resizesDesktop).toggleStyle(.switch)
              .controlSize(.small).fixedSize()
          }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.075), in: RoundedRectangle(cornerRadius: 12))
        if let local = session.localMac { LocalMacPermissionsSettings(runtime: local) }
        if session.imageUpdateAvailable && session.phase != .updating {
          Text("A newer image is available.").font(.caption).foregroundStyle(.orange)
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
          if session.offersImageUpgrade {
            ComputerImageUpdateButton(session: session) { updating = true }
          }
          if session.virtual != nil || session.container != nil || session.localMac != nil || session.windowsRuntime != nil
            || session.sshRuntime != nil {
            Button(stopLabel) { forceStopping = true }.disabled(session.phase.busy)
          }
        }
      }.padding(20)
    }
    .frame(width: 580).noodleSheetSizing()
    .computerImageUpdateConfirmation(store: store, session: session, isPresented: $updating)
    .sheet(isPresented: $changingSignIn) { ChangeSSHSignInView(store: store, session: session) }
    .onAppear {
      name = session.computer.name; description = session.computer.description ?? ""
      appearance = session.computer.appearance ?? .init()
      resizesDesktop = session.computer.resizesDesktop
      cpus = session.computer.cpuCount; memory = session.computer.memoryGiB
      disk = session.computer.diskGiB
      network = session.computer.networkEnabled
    }
    .alert(ComputerDeletion.title(session.computer), isPresented: $deleting) {
      Button("Cancel", role: .cancel) {}
      Button(ComputerDeletion.action(session.computer), role: .destructive) {
        store.remove(session)
        dismiss()
      }
    } message: {
      Text(ComputerDeletion.message(session.computer))
    }
    .computerStopConfirmation(isPresented: $forceStopping, name: session.computer.name, actionTitle: stopLabel) {
      guard !session.phase.busy, session.virtual != nil || session.container != nil || session.localMac != nil
        || session.windowsRuntime != nil || session.sshRuntime != nil else { return }
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
  @State private var resizesDesktop = true
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
              .buttonStyle(.plain).foregroundStyle(Color.accentColor)
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
            }.buttonStyle(.plain).foregroundStyle(canCreate ? Color.accentColor : .secondary)
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
              .buttonStyle(.plain).foregroundStyle(Color.accentColor)
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
            }.buttonStyle(.plain).foregroundStyle(canCreate ? Color.accentColor : .secondary)
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
            if let detail = store.creationDetail { Text(ComputerNotice.linked(detail)).monospacedDigit() }
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
          .buttonStyle(.plain).foregroundStyle(store.creationCancelling ? Color.secondary : .accentColor)
      }
    }
    .padding(24)
    .frame(width: 520)
    .interactiveDismissDisabled()
  }
}
