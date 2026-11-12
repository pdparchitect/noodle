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

/// The main window's sheets and panels, which menu commands open too.
@MainActor @Observable final class WindowState {
    enum Sheet: Identifiable {
        case newInvestigation, newGroup, newAgent, close(Investigation), members(BotConversation)
        var id: String {
            switch self {
            case .newInvestigation: "new-investigation"
            case .newGroup: "new-group"
            case .newAgent: "new-agent"
            case .close(let investigation): "close-\(investigation.id)"
            case .members(let conversation): "members-\(conversation.id)"
            }
        }
    }

    enum InspectorTab: String, CaseIterable { case caseRecord = "Case", audit = "Audit Log" }

    var sheet: Sheet?
    var showsInspector = true
    var inspectorTab: InspectorTab = .caseRecord
    /// Asks the composer of the selected conversation to take the keyboard.
    var composerFocusRequest = UUID()
}

struct PionCommands: Commands {
    let model: PionModel
    let window: WindowState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Investigation") { window.sheet = .newInvestigation }
                .keyboardShortcut("n")
                .disabled(model.agents.isEmpty)
            Button("New Group") { window.sheet = .newGroup }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(model.agents.isEmpty)
            Button("New Agent") { window.sheet = .newAgent }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Button(window.showsInspector ? "Hide Inspector" : "Show Inspector") { window.showsInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            ViewOptions()
            Divider()
        }
        CommandMenu("Investigation") {
            let investigation = model.investigation(model.selection)
            Menu("Status") {
                ForEach([Investigation.Status.open, .triaging, .contained], id: \.self) { status in
                    Button(status.title) { if let investigation { model.setStatus(status, of: investigation) } }
                        .disabled(investigation == nil || investigation?.status == status)
                }
            }
            .disabled(investigation?.isClosed != false)
            Button("Close Investigation…") { if let investigation { window.sheet = .close(investigation) } }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(investigation?.isClosed != false)
            Button("Reopen") { if let investigation { model.setStatus(.open, of: investigation) } }
                .disabled(investigation?.isClosed != true)
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
    }
}

enum SidebarOptions {
    static let showsClosedKey = "PionSidebarShowsClosed"
    /// How many closed Investigations the sidebar lists before offering more.
    static let closedShown = 5
}
