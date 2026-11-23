import AppKit
import HubLink
import NoodleCore
import NoodleRuntime
import NoodleRuntimeSettings
import NoodleSettingsUI
import PionCore
import SwiftUI

/// "Pion Dev" in development builds, so they are told apart from a released Pion.
let pionAppName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Pion"

@main struct PionEntry {
    static func main() {
        // A pipe whose other end closed is an error for its writer, never the end of Pion.
        signal(SIGPIPE, SIG_IGN)
        PionApp.main()
    }
}

struct PionApp: App {
    @NSApplicationDelegateAdaptor(PionDelegate.self) private var delegate

    var body: some Scene {
        // Noodle's main window scene: links that open Pion go to it, welcome or not, never to a new window.
        MainWindowScene {
            MainWindow(model: delegate.model, window: delegate.window, setup: delegate.settings.setup)
                .environment(delegate.calls)
                .environment(delegate.settings)
                .frame(minWidth: 980, minHeight: 640)
                // Pion's background effect over the window's own background, frosted or solid.
                .background { Backdrop().ignoresSafeArea() }
                .modifier(WindowSurfaceBackground())
        } onOpenURL: { [model = delegate.model] url in
            // pion://shared is the delegate's, as in Noodle; the rest finish a sign-in.
            if url.host != "shared" { _ = model.connectionsController.receiveAuthorizationCallback(url) }
        }
        .defaultSize(width: 1320, height: 840)
        // As in Noodle: even when Pion last quit with it closed, so its windows and notifications have it to open into.
        .defaultLaunchBehavior(.presented)
        // With the toolbar drawing no background, the window is moved by any empty part of it.
        .windowBackgroundDragBehavior(.enabled)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            PionCommands(model: delegate.model, window: delegate.window, calls: delegate.calls)
            // As in Noodle: View › Hide Sidebar (⌃⌘S).
            SidebarCommands()
            #if PION_DEV_HOOKS
            ScenarioCommands()
            #endif
        }
        WindowGroup("Conversation", id: "conversation", for: UUID.self) { $id in
            ConversationWindow(model: delegate.model, selection: $id)
                .environment(delegate.calls)
                .environment(delegate.settings)
                .frame(minWidth: 720, minHeight: 540)
                .background { Backdrop().ignoresSafeArea() }
                .modifier(WindowSurfaceBackground())
        }
        .defaultSize(width: 1000, height: 760)
        .defaultLaunchBehavior(.suppressed)
        // Noodle's window registry brings them back, each where it was left.
        .restorationBehavior(.disabled)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        Window("Usage", id: UsageView.windowID) {
            // Editing stays in the main window and Settings, where its sheet is.
            UsageView(history: delegate.model.usage, agents: delegate.model.everyAgent, storage: delegate.storage) { [model = delegate.model] agent in
                AnyView(AgentProfileButton(model: model, agent: agent, size: 16, phase: model.phase(of: agent), opensMessageInWindow: true))
            }
            .environment(delegate.calls)
            .environment(delegate.settings)
        }
        .defaultSize(width: 860, height: 680)
        .windowResizability(.contentMinSize)
        // Opened from the app menu, next to Settings.
        .commandsRemoved()
        Settings {
            PionSettingsView(host: delegate.settings)
                .environment(delegate.calls)
                .environment(delegate.settings)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor final class PionDelegate: NSObject, NSApplicationDelegate {
    let model: PionModel
    let window = WindowState()
    lazy var settings = PionSettingsHost(model: model)
    /// What Pion keeps on disk, for the Usage window.
    lazy var storage: StorageUsage = {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return StorageUsage(dataRoot: model.repository.rootURL, applicationSupport: applicationSupport,
                            library: applicationSupport.deletingLastPathComponent())
    }()
    lazy var calls: PionCalls = {
        let calls = PionCalls(model: model)
        calls.open = { [weak self] id in self?.showConversation(id) }
        return calls
    }()

    override init() {
        // Before anything adds or uses a tool connection, or reads a shortcut.
        ToolCatalog.use(PionCatalogue.entries)
        KeyboardBindings.catalog = PionShortcuts.catalog
        // Noodle's sidebar line, but an agent's row says what it does until the champion picks otherwise.
        UserDefaults.standard.register(defaults: [ConversationRowDetail.key: ConversationRowDetail.description.rawValue])
        // As in Noodle: the View menu carries its own Full Screen item, after a divider.
        UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false])
        #if PION_DEV_HOOKS
        if let scenario = ScenarioSession.launch() {
            model = scenario.model
            super.init()
            scenario.window = window
            return
        }
        #endif
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var rehearsing = false
        #if PION_DEV_HOOKS
        // --rehearse: as on a Mac that never had Pion or any harness, in a folder of its own emptied each time,
        // to walk through the welcome with real downloads and sign-ins. Your own agents and logins are kept.
        if CommandLine.arguments.contains("--rehearse") {
            do { try Rehearsal.begin(in: applicationSupport) } catch { fatalError("Could not start the rehearsal: \(error)") }
            rehearsing = true
            UserDefaults.standard.removeObject(forKey: PionModel.welcomeDismissedKey)
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("NSWindow Frame ") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        } else {
            Rehearsal.end(in: applicationSupport)
        }
        #endif
        let messenger = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/messenger")
        model = PionModel(root: HarnessStorage.dataRoot(applicationSupport: applicationSupport),
                          messenger: FileManager.default.isExecutableFile(atPath: messenger.path) ? messenger : nil,
                          hidesInstalledHarnesses: rehearsing)
        super.init()
    }

    private var harnessUpdates: Task<Void, Never>?
    /// Services › Send to Agent…, as in Noodle.
    private lazy var services = NoodleServices(publish: { [weak self] in self?.model.publishShareDestinations() },
                                               deliver: { [weak self] in await self?.model.deliverShared() })
    /// Noodle's error alert, over whichever window is in front, sheets included.
    private var errorAlert: StoreErrorAlert?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = settings
        _ = calls
        PionIntentApp.delegate = self
        if !model.isScripted {
            NSApp.servicesProvider = services
            NSUpdateDynamicServices()
        }
        errorAlert = StoreErrorAlert(title: pionAppName, message: { [weak self] in self?.model.problem },
                                     clear: { [weak self] in self?.model.problem = nil })
        // Noodle's floating conversations, showing Pion's conversation view.
        // Noodle's registry of conversation windows: what is on screen is read, and separate windows open again.
        let windows = ConversationWindowRegistry(fileURL: model.repository.rootURL.appendingPathComponent("conversation-windows.json"))
        PionWindows.conversations = windows
        model.isViewing = { windows.isViewing($0) }
        PionWindows.panels = FloatingConversationPanels(floating: .shared, isTerminating: { windows.isTerminating },
            toggleCall: { [weak self] in self?.calls.toggleCall(in: $0) }) { [weak self] id, commands in
            guard let self else { return NSView() }
            let view = NSHostingView(rootView: ConversationWindow(model: self.model, selection: .constant(id))
                .environment(self.calls).environment(self.settings).environment(\.floatingPanelCommands, commands)
                .background { FloatingWindowBackdrop().ignoresSafeArea() })
            // The panel owns its size; the conversation must not resize it to fit.
            view.sizingOptions = []
            return view
        }
        if !model.isScripted { connectNotifications() }
        model.start()
        if !model.isScripted { calls.ringPendingCalls() }
        // As in Noodle, what floated when Pion quit floats again.
        FloatingConversations.shared.retain(Set(model.conversations.map(\.id)))
        // Every conversation, an archived one too, which can still be open in a window of its own.
        let retain = { [weak self] in
            guard let self else { return }
            windows.retainConversations(Set(self.model.everyConversation.map(\.id)))
            guard !self.model.isScripted else { return }
            self.model.publishShareDestinations()
            // As Noodle's: Siri and Spotlight offer the conversations by name.
            PionAppShortcuts.updateAppShortcutParameters()
        }
        model.onConversationsChanged = retain
        retain()
        for id in FloatingConversations.shared.ids { PionWindows.float(id) }
        model.offerWelcome()
        // Noodle's updater, on Pion's own channel; it stays off in development builds.
        if !model.isScripted { AppUpdater.shared.start() }
        // As in Noodle, the harnesses Pion installed are kept current while it runs.
        if !model.isScripted { harnessUpdates = settings.setup.keepUpdated(model.runtime) }
        #if PION_DEV_HOOKS
        ScenarioSession.active?.begin()
        #endif
    }

    /// As in Noodle: a window already showing the conversation comes forward, else the main window shows it.
    func showConversation(_ id: UUID) {
        if PionWindows.conversations?.focus(id) != true {
            model.selection = id
            window.openMain?()
        }
    }

    /// Send to Pion's wake-up, pion://shared, which carries nothing: what it sent waits in the app group. Handled here,
    /// as Noodle handles noodle://shared, so it arrives with no window open to take it.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.host == "shared" }) else { return }
        Task { await model.deliverShared() }
    }

    /// Send to Pion wakes Pion with pion://shared, but what it sent is also picked up whenever Pion comes forward.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !model.isScripted else { return }
        model.publishShareDestinations()
        Task { await model.deliverShared() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let working = model.agents.filter { model.phase(of: $0) == .working }
        guard !model.isScripted, !working.isEmpty else { PionWindows.conversations?.prepareForTermination(); return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit \(pionAppName)?"
        alert.informativeText = "\(working.count == 1 ? "1 agent is" : "\(working.count) agents are") working. They stop until \(pionAppName) opens again."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        PionWindows.conversations?.prepareForTermination()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        harnessUpdates?.cancel()
        model.stop()
    }
}

/// Scene focus keeps menu actions on the key conversation, rather than the main sidebar's selection.
struct ConversationCommandContext {
    let selection: Binding<UUID?>
    let window: WindowState
    /// Nil where there is no sidebar to search.
    let search: (() -> Void)?
}

private struct ConversationCommandKey: FocusedValueKey { typealias Value = ConversationCommandContext }

extension FocusedValues {
    var pionConversation: ConversationCommandContext? {
        get { self[ConversationCommandKey.self] }
        set { self[ConversationCommandKey.self] = newValue }
    }
}

struct PionCommands: Commands {
    let model: PionModel
    let window: WindowState
    let calls: PionCalls
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.pionConversation) private var context
    @FocusedValue(\.voiceRecordingCommand) private var voiceRecording
    private let annotations = AnnotationCommandsState.shared

    private var activeWindow: WindowState { context?.window ?? window }
    private var conversationID: UUID? { context?.selection.wrappedValue }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesButton()
        }
        // "After Settings" draws above it; this section sits between Settings and Services, as in Noodle.
        CommandGroup(before: .systemServices) {
            Button {
                model.usage.agentFilter = nil
                openWindow(id: UsageView.windowID)
            } label: {
                Label("Usage", systemImage: "chart.bar").labelStyle(.titleAndIcon)
            }
            .appShortcut(PionShortcuts.usage)
            Divider()
        }
        CommandGroup(replacing: .help) {
            // As Noodle's: its own page in the repository, where its README explains it.
            Button("\(pionAppName) Help") {
                NSWorkspace.shared.open(URL(string: "https://github.com/pdparchitect/noodle/tree/main/Incubator/Pion")!)
            }
            Divider()
            IssueReportButtons(area: "Incubator / Pion")
            Divider()
            Button("Welcome") {
                // The welcome fills the main window, which may be closed.
                openWindow(id: "main")
                model.showWelcome()
            }
        }
        CommandGroup(after: .pasteboard) {
            // As Noodle's: handled by the focused composer; elsewhere nothing answers and the menu beeps.
            Button("Paste as Attachment") {
                NSApp.sendAction(#selector(ComposerTextView.pasteAsAttachment(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("v", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .newItem) {
            Button("New Investigation") { activeWindow.sheet = .newInvestigation }
                .appShortcut(PionShortcuts.newInvestigation)
                .disabled(model.agents.isEmpty)
            Button("New Group") { activeWindow.sheet = .newGroup }
                .appShortcut(PionShortcuts.newGroup)
                .disabled(model.agents.isEmpty)
            Button("New Agent") { activeWindow.sheet = .newAgent }
                .appShortcut(PionShortcuts.newAgent)
        }
        CommandGroup(after: .sidebar) {
            Button(activeWindow.showsInspector ? "Hide Inspector" : "Show Inspector") { activeWindow.showsInspector.toggle() }
                .appShortcut(PionShortcuts.showInspector)
                .disabled(model.investigation(conversationID) == nil)
            Divider()
            ViewOptions()
            Divider()
            FullScreenCommand()
        }
        CommandMenu("Conversation") {
            Button("Search Conversations") { context?.search?() }
                .appShortcut(PionShortcuts.searchConversations)
                .disabled(context?.search == nil)
            Divider()
            Button("Open in New Window") { if let conversationID { PionWindows.dock(conversationID) } }
            .disabled(conversationID == nil)
            Button("Float on Top") {
                // As in Noodle, the panel takes the place of the conversation's own window if it has one.
                if let conversationID { PionWindows.float(conversationID) }
            }
            .disabled(conversationID == nil)
            Button("Export Investigation…") {
                if let investigation = model.investigation(conversationID) { model.exportInvestigation(investigation) }
            }
            .disabled(model.investigation(conversationID) == nil)
            Divider()
            // Noodle's annotation commands, on the key conversation or the preview in front.
            Button("Add Annotation…") { annotations.conversationOwner?.annotate() }
                .appShortcut(.annotateSelection)
                .disabled(!annotations.conversationEnabled)
            Button("Annotate Region…") { annotations.conversationOwner?.startRegion() }
                .appShortcut(.annotateRegion)
                .disabled(!annotations.conversationEnabled)
            Divider()
            // Noodle's command, published by the composer of the key conversation.
            Button(voiceRecording?.title ?? "Record Voice Message") { voiceRecording?.perform() }
                .appShortcut(PionShortcuts.recordVoice)
                .disabled(voiceRecording?.isEnabled != true)
            CallCommandButton(isOnCall: calls.voiceCalls.call != nil) { calls.toggleCall(in: conversationID) }
                .disabled(calls.voiceCalls.call == nil && model.conversation(conversationID).map(calls.canCallNow) != true)
            Button("Stop") { model.stop(in: conversationID) }
                .appShortcut(PionShortcuts.stop)
                .disabled(model.stoppableAgent(in: conversationID) == nil)
        }
    }
}

/// View › Background › Frosted or Solid: whether the desktop shows through the window.
enum WindowSurface: String {
    case frosted, solid
    static let key = "PionWindowSurface"
    /// View › Background › Tint: whether the window carries the faint wash of the accent, on unless turned off.
    static let tintKey = "PionWindowTint"
}

/// The window's background for the chosen surface: Solid is a normal window's own background, Frosted the system's
/// frosted glass over the desktop behind the content. Not a SwiftUI container background for the window, which
/// made every step of a resize several times slower.
struct WindowSurfaceBackground: ViewModifier {
    @AppStorage(WindowSurface.key) private var surface = WindowSurface.frosted
    @AppStorage(WindowSurface.tintKey) private var tinted = true

    func body(content: Content) -> some View {
        content.background {
            ZStack {
                if surface == .frosted { FrostedWindowBackground() }
                // A faint wash of the accent over either surface, so the window reads as Pion's blue team.
                if tinted { Color.windowWash }
            }
            .ignoresSafeArea()
        }
    }
}

extension Color {
    /// The accent, faint enough to tint the window without colouring its text or controls; a touch stronger on a dark
    /// window, where the same amount reads weaker.
    static let windowWash = Color(nsColor: NSColor(name: nil) { appearance in
        let accent = NSColor(named: "AccentColor") ?? .controlAccentColor
        return accent.withAlphaComponent(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.16 : 0.07)
    })
}

/// The desktop behind the window, blurred, as macOS draws translucent window backgrounds.
private struct FrostedWindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// View › Background (Frosted or Solid, and the effect), View › Sidebar and View › Conversation, in Noodle's order, kept per
/// person as Noodle keeps its view options.
struct ViewOptions: View {
    @AppStorage(ConversationListStyle.key) private var sidebarStyle = ConversationListStyle.standard.rawValue
    @AppStorage(SidebarOptions.showsClosedKey) private var showsClosed = false
    @AppStorage(BackdropEffect.key) private var effect = BackdropEffect.standard.rawValue
    @AppStorage(WindowSurface.key) private var surface = WindowSurface.frosted
    @AppStorage(WindowSurface.tintKey) private var tinted = true

    var body: some View {
        // Everything about the window's background in one submenu: the surface, then the effect over it.
        Menu("Background") {
            Picker("Surface", selection: $surface) {
                Text("Frosted").tag(WindowSurface.frosted)
                Text("Solid").tag(WindowSurface.solid)
            }
            .pickerStyle(.inline)
            .labelsHidden()
            // The accent's wash, apart from the surface, for those who prefer the window plain.
            Section { Toggle("Tint", isOn: $tinted) }
            // Checkmark items rather than an inline picker, which draws a separator of its own.
            Section {
                ForEach(BackdropEffect.offered) { offered in
                    Toggle(offered.title, isOn: Binding(get: { effect == offered.rawValue },
                                                        set: { if $0 { effect = offered.rawValue } }))
                }
            }
        }
        Divider()
        Menu("Sidebar") {
            Picker("Style", selection: $sidebarStyle) {
                ForEach(ConversationListStyle.allCases) { Text($0.name).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            // Noodle's: the line under each name, the order and the agents' tasks.
            SidebarListPickers()
            // Last, where Noodle keeps its own Show items.
            Divider()
            Toggle("Show Closed Investigations", isOn: $showsClosed)
            SidebarToolsToggle()
        }
        // Noodle's, without its choices for long messages: Pion keeps its own reading style.
        Menu("Conversation") { AttachmentLayoutChoices() }
    }
}

enum SidebarOptions {
    static let showsClosedKey = "PionSidebarShowsClosed"
    /// How many closed Investigations the sidebar lists before offering more.
    static let closedShown = 5
}

/// Noodle's conversation windows: its registry of what each window shows, and its floating conversations, kept above
/// other apps, on every Space, and floating again after Pion opens.
@MainActor enum PionWindows {
    static var conversations: ConversationWindowRegistry?
    static var panels: FloatingConversationPanels?

    static func float(_ id: UUID) {
        guard let conversations, let panels else { return }
        conversations.float(id, in: panels)
    }

    /// Opens the conversation in its own window, or brings that window forward, and stops it floating, as Noodle
    /// docks it.
    static func dock(_ id: UUID) {
        guard let conversations, let panels else { return }
        conversations.dock(id, panels: panels)
    }

    /// Shows the conversation in the main window, closing its own window or panel.
    static func returnToMainWindow(_ id: UUID, model: PionModel) {
        guard let conversations, let panels else { return }
        conversations.returnToMainWindow(id, panels: panels) { model.selection = $0 }
    }
}
