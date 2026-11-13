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
                .frame(minWidth: 980, minHeight: 640)
                // The desktop shows through, frosted, with Pion's falling glyphs under the frost.
                .background { Backdrop().ignoresSafeArea() }
                .containerBackground(.thickMaterial, for: .window)
        }
        .defaultSize(width: 1320, height: 840)
        // With the toolbar drawing no background, the window is moved by any empty part of it.
        .windowBackgroundDragBehavior(.enabled)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            PionCommands(model: delegate.model, window: delegate.window)
            #if PION_DEV_HOOKS
            ScenarioCommands()
            #endif
        }
        WindowGroup("Conversation", id: "conversation", for: UUID.self) { $id in
            ConversationWindow(model: delegate.model, selection: $id)
                .frame(minWidth: 720, minHeight: 540)
                .background { Backdrop().ignoresSafeArea() }
                .containerBackground(.thickMaterial, for: .window)
        }
        .defaultSize(width: 1000, height: 760)
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        Settings {
            PionSettingsView(host: delegate.settings)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor final class PionDelegate: NSObject, NSApplicationDelegate {
    let model: PionModel
    let window = WindowState()
    lazy var settings = PionSettingsHost(model: model)

    override init() {
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
        model.start()
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
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.pionConversation) private var context
    @FocusedValue(\.pionDictation) private var dictation

    private var activeWindow: WindowState { context?.window ?? window }
    private var conversationID: UUID? { context?.selection.wrappedValue }

    var body: some Commands {
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
            Divider()
            Button(dictation?.isRecording == true ? "Stop Dictation" : "Dictate") { dictation?.perform() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(dictation?.isEnabled != true)
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

/// View › Sidebar and View › Background Effect, kept per person as Noodle keeps its view options.
struct ViewOptions: View {
    @AppStorage(SidebarOptions.showsClosedKey) private var showsClosed = false
    @AppStorage(BackdropEffect.key) private var effect = BackdropEffect.glyphs.rawValue

    var body: some View {
        Menu("Sidebar") {
            Toggle("Show Closed Investigations", isOn: $showsClosed)
        }
        Picker("Background Effect", selection: $effect) {
            ForEach(BackdropEffect.allCases) { effect in
                Text(effect.title).tag(effect.rawValue)
                if effect == .none { Divider() }
            }
        }
        .pickerStyle(.menu)
    }
}

enum SidebarOptions {
    static let showsClosedKey = "PionSidebarShowsClosed"
    /// How many closed Investigations the sidebar lists before offering more.
    static let closedShown = 5
}
