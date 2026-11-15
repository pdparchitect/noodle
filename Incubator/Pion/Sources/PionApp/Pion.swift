import AppKit
import NoodleCore
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
        Window(pionAppName, id: "main") {
            MainWindow(model: delegate.model, window: delegate.window)
                .environment(delegate.calls)
                .frame(minWidth: 980, minHeight: 640)
                // Pion's background effect over the window's own background, frosted or solid.
                .background { Backdrop().ignoresSafeArea() }
                .modifier(WindowSurfaceBackground())
        }
        .defaultSize(width: 1320, height: 840)
        // With the toolbar drawing no background, the window is moved by any empty part of it.
        .windowBackgroundDragBehavior(.enabled)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            PionCommands(model: delegate.model, window: delegate.window, calls: delegate.calls)
            #if PION_DEV_HOOKS
            ScenarioCommands()
            #endif
        }
        WindowGroup("Conversation", id: "conversation", for: UUID.self) { $id in
            ConversationWindow(model: delegate.model, selection: $id)
                .environment(delegate.calls)
                .frame(minWidth: 720, minHeight: 540)
                .background { Backdrop().ignoresSafeArea() }
                .modifier(WindowSurfaceBackground())
        }
        .defaultSize(width: 1000, height: 760)
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        Settings {
            PionSettingsView(host: delegate.settings)
                .environment(delegate.calls)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor final class PionDelegate: NSObject, NSApplicationDelegate {
    let model: PionModel
    let window = WindowState()
    lazy var settings = PionSettingsHost(model: model)
    lazy var calls: PionCalls = {
        let calls = PionCalls(model: model)
        calls.open = { [weak self] id in
            self?.model.selection = id
            self?.window.openMain?()
        }
        return calls
    }()

    override init() {
        // Before anything adds or uses a tool connection.
        ToolCatalog.use(PionCatalogue.entries)
        #if PION_DEV_HOOKS
        if let scenario = ScenarioSession.launch() {
            model = scenario.model
            super.init()
            scenario.window = window
            return
        }
        #endif
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let messenger = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/messenger")
        model = PionModel(root: HarnessStorage.dataRoot(applicationSupport: applicationSupport),
                          messenger: FileManager.default.isExecutableFile(atPath: messenger.path) ? messenger : nil)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = settings
        _ = calls
        if !model.isScripted { connectNotifications() }
        model.start()
        // Noodle's updater, on Pion's own channel; it stays off in development builds.
        if !model.isScripted { AppUpdater.shared.start() }
        #if PION_DEV_HOOKS
        ScenarioSession.active?.begin()
        #endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let working = model.agents.filter { model.phase(of: $0) == .working }
        guard !model.isScripted, !working.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit \(pionAppName)?"
        alert.informativeText = "\(working.count == 1 ? "1 agent is" : "\(working.count) agents are") working. They stop until \(pionAppName) opens again."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) { model.stop() }
}

/// Scene focus keeps menu actions on the key conversation, rather than the main sidebar's selection.
struct ConversationCommandContext {
    let selection: Binding<UUID?>
    let window: WindowState
    let search: () -> Void
}

struct DictationCommand {
    let isRecording: Bool
    let isEnabled: Bool
    let toggle: () -> Void

    @MainActor func perform() {
        guard isEnabled, NSApp.modalWindow == nil, let window = NSApp.keyWindow,
              window.attachedSheet == nil, window.sheetParent == nil,
              NSApp.currentEvent?.isARepeat != true else { return }
        toggle()
    }
}

private struct ConversationCommandKey: FocusedValueKey { typealias Value = ConversationCommandContext }
private struct DictationCommandKey: FocusedValueKey { typealias Value = DictationCommand }

extension FocusedValues {
    var pionConversation: ConversationCommandContext? {
        get { self[ConversationCommandKey.self] }
        set { self[ConversationCommandKey.self] = newValue }
    }
    var pionDictation: DictationCommand? {
        get { self[DictationCommandKey.self] }
        set { self[DictationCommandKey.self] = newValue }
    }
}

struct PionCommands: Commands {
    let model: PionModel
    let window: WindowState
    let calls: PionCalls
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.pionConversation) private var context
    @FocusedValue(\.pionDictation) private var dictation
    private let annotations = AnnotationCommandsState.shared

    private var activeWindow: WindowState { context?.window ?? window }
    private var conversationID: UUID? { context?.selection.wrappedValue }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesButton()
        }
        CommandGroup(replacing: .newItem) {
            Button("New Investigation") { activeWindow.sheet = .newInvestigation }
                .keyboardShortcut("n")
                .disabled(model.agents.isEmpty)
            Button("New Group") { activeWindow.sheet = .newGroup }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(model.agents.isEmpty)
            Button("New Agent") { activeWindow.sheet = .newAgent }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Button(activeWindow.showsInspector ? "Hide Inspector" : "Show Inspector") { activeWindow.showsInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(model.investigation(conversationID) == nil)
            Divider()
            ViewOptions()
            Divider()
        }
        CommandMenu("Conversation") {
            Button("Search Conversations") { context?.search() }
                .keyboardShortcut("f")
                .disabled(context == nil)
            Button("Choose Conversation…") { activeWindow.sheet = .chooseConversation }
                .keyboardShortcut(.space, modifiers: [.control, .option])
                .disabled(context == nil)
            Divider()
            Button("Open in New Window") {
                if let conversationID { openWindow(id: "conversation", value: conversationID) }
            }
            .disabled(conversationID == nil)
            Toggle("Float on Top", isOn: Binding(get: { activeWindow.floatsOnTop }, set: {
                activeWindow.floatsOnTop = $0
                NSApp.keyWindow?.level = $0 ? .floating : .normal
            }))
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
            Button(dictation?.isRecording == true ? "Stop Dictation" : "Dictate") { dictation?.perform() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(dictation?.isEnabled != true)
            Button(calls.voiceCalls.call != nil ? "End Call" : "Call") { calls.toggleCall(in: conversationID) }
                .appShortcut(.call)
                .disabled(calls.voiceCalls.call == nil && model.conversation(conversationID).map(calls.canCallNow) != true)
            Button("Stop") { model.stop(in: conversationID) }
                .keyboardShortcut(".")
                .disabled(model.stoppableAgent(in: conversationID) == nil)
        }
    }
}

extension Notification.Name {
    /// Asks the transcript Pion shares with Noodle to scroll to a message; Noodle declares the same name in its own app.
    static let revealTranscriptMessage = Notification.Name("Pion.revealTranscriptMessage")
}

/// View › Background › Frosted or Solid: whether the desktop shows through the window.
enum WindowSurface: String {
    case frosted, solid
    static let key = "PionWindowSurface"
}

/// The window's background for the chosen surface: frosted glass over the desktop, or the plain window colour.
struct WindowSurfaceBackground: ViewModifier {
    @AppStorage(WindowSurface.key) private var surface = WindowSurface.frosted

    func body(content: Content) -> some View {
        content.containerBackground(surface == .solid ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                                                      : AnyShapeStyle(.thickMaterial), for: .window)
    }
}

/// View › Background (Frosted or Solid, and the effect) and View › Sidebar, kept per person as Noodle keeps its view options.
struct ViewOptions: View {
    @AppStorage(SidebarOptions.showsClosedKey) private var showsClosed = false
    @AppStorage(BackdropEffect.key) private var effect = BackdropEffect.standard.rawValue
    @AppStorage(WindowSurface.key) private var surface = WindowSurface.frosted

    var body: some View {
        // Everything about the window's background in one submenu: the surface, then the effect over it.
        Menu("Background") {
            Picker("Surface", selection: $surface) {
                Text("Frosted").tag(WindowSurface.frosted)
                Text("Solid").tag(WindowSurface.solid)
            }
            .pickerStyle(.inline)
            .labelsHidden()
            // Checkmark items rather than an inline picker, which draws a separator of its own under the header.
            Section("Animation") {
                ForEach(BackdropEffect.offered) { offered in
                    Toggle(offered.title, isOn: Binding(get: { effect == offered.rawValue },
                                                        set: { if $0 { effect = offered.rawValue } }))
                    if offered == .none { Divider() }
                }
            }
        }
        Divider()
        Menu("Sidebar") {
            Toggle("Show Closed Investigations", isOn: $showsClosed)
        }
    }
}

enum SidebarOptions {
    static let showsClosedKey = "PionSidebarShowsClosed"
    /// How many closed Investigations the sidebar lists before offering more.
    static let closedShown = 5
}
