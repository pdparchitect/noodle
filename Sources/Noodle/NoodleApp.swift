import AppKit
import Darwin
import SwiftUI
import NoodleCore
import NoodleLaunchChecks
import NoodleRuntime
import NoodleRuntimeSettings
import NoodleSettingsUI
import UserNotifications
import NoodleWallpaper
#if NOODLE_DEV_HOOKS
import os
#endif

/// Claims the app's single running copy before SwiftUI makes its delegate, which opens its data.
@main enum NoodleEntry {
    static func main() {
        if !MessengerCLI.shouldHandle() { AppInstance.claim() }
        NoodleApp.main()
    }
}

struct NoodleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: NoodleStore
    @State private var errorAlert: StoreErrorAlert

    init() {
        // The View menu carries its own Full Screen item, after the layouts and a divider.
        UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false])
        #if NOODLE_DEV_HOOKS
        // Development builds only. Each hook runs an isolated fixture in place of the app and exits.
        Logger(subsystem: "com.pdparchitect.noodle", category: "DevelopmentHooks").notice("noodle.development-hooks.enabled")
        let checks = LaunchChecks.current
        if checks.contains(DevelopmentHook.browserIntegration) || checks.contains(DevelopmentHook.browserDiscovery) || checks.contains(DevelopmentHook.browserPicker) {
            NSApplication.shared.setActivationPolicy(.accessory)
            Task { @MainActor in
                do {
                    if checks.contains(DevelopmentHook.browserPicker) { try await BrowserPickerIntegrationTest.run() }
                    else if checks.contains(DevelopmentHook.browserDiscovery) { try await BrowserIntegrationTest.checkDiscovery() }
                    else { try await BrowserIntegrationTest.run() }
                    Darwin.exit(0)
                }
                catch { print("BROWSER INTEGRATION FAILED: \(error.localizedDescription)"); Darwin.exit(1) }
            }
            NSApplication.shared.run()
            Darwin.exit(1)
        }
        if checks.contains(DevelopmentHook.appletLink) {
            NSApplication.shared.setActivationPolicy(.regular)
            Task { @MainActor in
                do { try await AppletLinkIntegrationTest.run(); Darwin.exit(0) }
                catch { print("APPLET LINK INTEGRATION FAILED: \(error.localizedDescription)"); Darwin.exit(1) }
            }
            NSApplication.shared.run()
            Darwin.exit(1)
        }
        if checks.contains(DevelopmentHook.computerIntegration) || checks.contains(DevelopmentHook.computerDiscovery) || checks.contains(DevelopmentHook.computerPicker) {
            NSApplication.shared.setActivationPolicy(.regular)
            Task { @MainActor in
                do {
                    if checks.contains(DevelopmentHook.computerPicker) { try await ComputerIntegrationTest.checkPicker() }
                    else if checks.contains(DevelopmentHook.computerDiscovery) { try await ComputerIntegrationTest.checkDiscovery() }
                    else { try await ComputerIntegrationTest.run() }
                    Darwin.exit(0)
                }
                catch { print("COMPUTER INTEGRATION FAILED: \(error.localizedDescription)"); Darwin.exit(1) }
            }
            NSApplication.shared.run()
            Darwin.exit(1)
        }
        // The scenarios bundle opens a scripted store and never the app's own data; see Scenario.swift.
        if let store = ScenarioSession.launch(checks) {
            _store = State(initialValue: store)
            _errorAlert = State(initialValue: StoreErrorAlert(store: store))
            return
        }
        #endif
        if MessengerCLI.shouldHandle() {
            let result = MessengerCLI.run()
            Self.write(result.standardOutput, to: .standardOutput)
            Self.write(result.standardError, to: .standardError)
            Darwin.exit(result.exitCode)
        }
        #if NOODLE_DEV_HOOKS
        // Only the app itself decides: a messenger call from a rehearsal's bot must not end it.
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if LaunchChecks.current.contains(DevelopmentHook.rehearse) {
            do { try Rehearsal.begin(in: applicationSupport) } catch { fatalError("Could not start the rehearsal: \(error)") }
            // As on a first launch: the welcome is offered even after Not Now, and windows open
            // where a first launch puts them, not where the last session left them.
            UserDefaults.standard.removeObject(forKey: FirstBotSetup.dismissedKey)
            // Set here, for this run only: as a launch argument its value would be opened as a file.
            UserDefaults.standard.setVolatileDomain(
                UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
                    .merging(["ApplePersistenceIgnoreState": true]) { $1 },
                forName: UserDefaults.argumentDomain)
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("NSWindow Frame ") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        } else {
            Rehearsal.end(in: applicationSupport)
        }
        #endif
        let store = NoodleStore()
        store.startMonitoring()
        _store = State(initialValue: store)
        _errorAlert = State(initialValue: StoreErrorAlert(store: store))
    }

    var body: some Scene {
        MainWindowScene {
            RootView()
                .environment(store)
                .frame(minWidth: 980, minHeight: 670)
                .background(WindowConfiguration())
        } onOpenURL: {
            if !store.openWidgetLink($0), !store.receiveHubInvitation($0) { store.mcp.receiveAuthorizationCallback($0) }
        }
        .defaultSize(width: 1160, height: 810)
        // Until the person moves it, which macOS then restores.
        .defaultWindowPlacement { _, _ in WindowPlacement(.center) }
        // Even when the last session ended with it closed, or Noodle would open to nothing but its Dock icon.
        .defaultLaunchBehavior(.presented)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(before: .toolbar) {
                MainWindowLayoutCommands()
                Divider()
                SidebarCommands()
                ConversationLayoutCommands()
                Divider()
                FullScreenCommand()
            }
            CommandGroup(replacing: .help) {
                Button("\(NoodleAppIdentity.name) Help") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/pdparchitect/noodle")!)
                }
                Divider()
                BotSetupCommand(store: store)
                Divider()
                ConnectCommand(store: store)
            }
            CommandGroup(after: .appSettings) {
                CheckForUpdatesButton()
            }
            // "After Settings" draws above it; this section sits between Settings and Services.
            CommandGroup(before: .systemServices) {
                UsageMenuButton(history: store.usage)
                Divider()
            }
            CommandGroup(after: .pasteboard) {
                // Handled by the focused composer; elsewhere nothing answers and the menu beeps.
                Button("Paste as Attachment") {
                    NSApp.sendAction(#selector(ComposerTextView.pasteAsAttachment(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("v", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .newItem) {
                Button("New Bot") {
                    NotificationCenter.default.post(name: .newBot, object: nil)
                }
                .appShortcut(.newBot)
                .disabled(!store.canCreateBot)

                Button("New Group") {
                    NotificationCenter.default.post(name: .newGroup, object: nil)
                }
                .appShortcut(.newGroup)
            }

            ConversationCommands(search: {
                NotificationCenter.default.post(name: .focusSearch, object: nil)
            }, openInNewWindow: {
                if let id = store.conversationWindows.conversationID(in: NSApp.keyWindow) { store.dockConversation(id) }
            }, floatOnTop: {
                if let id = store.conversationWindows.conversationID(in: NSApp.keyWindow) { store.floatConversation(id) }
            }, isOnCall: { store.voiceCalls.call != nil }, toggleCall: {
                store.toggleVoiceCall(in: store.conversationWindows.conversationID(in: NSApp.keyWindow))
            })
            SpaceCommands(store: store)
            CompanionAppCommands(store: store)
            #if NOODLE_DEV_HOOKS
            ScenarioCommands()
            #endif
        }

        WindowGroup("Conversation", id: "conversation", for: UUID.self) { $conversationID in
            if let conversationID {
                ConversationWindowView(conversationID: conversationID)
                    .environment(store)
                    .frame(minWidth: 560, minHeight: 500)
            }
        }
        .defaultSize(width: 760, height: 810)
        // Restore from the workspace even after a crash or when macOS Resume is off.
        .restorationBehavior(.disabled)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))

        Window("Usage", id: UsageView.windowID) {
            NoodleUsageView()
                .environment(store)
        }
        .defaultSize(width: 860, height: 680)
        .windowResizability(.contentMinSize)
        // Opened from the app menu, next to Settings.
        .commandsRemoved()

        Settings {
            NoodleSettingsView()
                .environment(store)
        }
        .windowResizability(.contentSize)
    }

    private static func write(_ value: String, to handle: FileHandle) {
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = NoodleServices()

    func applicationDidFinishLaunching(_ notification: Notification) {
        WindowFocusGuard.shared.start()
        OrphanedSheetSweeper.shared.start()
        AgentPickerController.shared.start()
        NSApp.setActivationPolicy(.regular)
        NoodleStore.active?.updateDockBadge()
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        #if NOODLE_DEV_HOOKS
        // A new bundle identifier would ask for notification permission over the screenshot.
        if ScenarioSession.active == nil { NoodleNotifications.configure(delegate: self) }
        #else
        NoodleNotifications.configure(delegate: self)
        #endif
        // A migration milestone must finish before Sparkle can offer its successor.
        if NoodleStore.active?.storageReady == true { AppUpdater.shared.start() }
        // A force quit mid-download leaves partial weights that nothing lists.
        if let root = NoodleStore.active?.repository.rootURL {
            Task.detached(priority: .utility) { AppleLocalModelStore(repository: root).removeAbandonedStaging() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        NoodleStore.active?.conversationWindows.prepareForTermination()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NoodleStore.active?.stopMonitoring()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        NoodleStore.active?.applets.refreshSkills()
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        NoodleStore.active?.recoverAgentsAfterWake()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        let scheme = (types?.first?["CFBundleURLSchemes"] as? [String])?.first ?? "noodle"
        guard urls.contains(where: { $0.scheme == scheme && $0.host == "shared" }) else { return }
        Task { await NoodleStore.active?.processSharedInbox() }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let signIn = notification.request.content.userInfo[NoodleNotifications.signInKey] != nil
        // A ringing call only rings, in front or not: its panel shows who calls.
        let call = notification.request.content.userInfo[NoodleNotifications.callKey] != nil
        Task { @MainActor in
            completionHandler(
                call ? [.sound] : signIn || NoodleNotifications.shouldPresentActivity ? [.banner, .sound] : []
            )
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let conversationID = (userInfo[NoodleNotifications.conversationIDKey] as? String).flatMap(UUID.init)
        let messageID = (userInfo[NoodleNotifications.messageIDKey] as? String).flatMap(UUID.init)
        let signIn = userInfo[NoodleNotifications.signInKey] != nil

        Task { @MainActor in
            if signIn {
                NoodleStore.active?.showHarnessSettings()
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            if let conversationID {
                NoodleStore.active?.openNotification(conversationID: conversationID, messageID: messageID)
            }
            NSApp.activate(ignoringOtherApps: true)
            completionHandler()
        }
    }
}

extension Notification.Name {
    static let newBot = Notification.Name("Noodle.newBot")
    static let newGroup = Notification.Name("Noodle.newGroup")
    static let focusSearch = Notification.Name("Noodle.focusSearch")
}

private struct WindowConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.title = NoodleAppIdentity.name
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        window.minSize = NSSize(width: 980, height: 670)
        window.isReleasedWhenClosed = false
    }
}

struct RootView: View {
    @Environment(NoodleStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var isFileDropTargeted = false
    @State private var composerFocusRequest = UUID()
    @State private var sidebarFocusRequest = UUID()
    /// The Kick alert of the selected conversation's paused bot, asked for from the toolbar.
    @State private var kickRequest: AgentKickRequest?
    @State private var toolbarState = MainToolbarState()
    @AppStorage(MainWindowLayout.key) private var layout = MainWindowLayout.list
    @State private var columns = ColumnsModel()
    private var showsColumns: Bool { layout == .columns }

    var body: some View {
        Group {
            if store.showsWelcome {
                WelcomeView()
            } else if store.showsConnect {
                ConnectView()
            } else {
                content()
            }
        }
        .task(id: store.storageReady) {
            guard store.storageReady else { return }
            store.offerFirstBotSetup()
            store.conversationWindows.openMainWindow = { openWindow(id: "main") }
            await store.thisMac.restore()
            store.conversationWindows.restoreWindows { id in
                // A conversation left floating comes back as a panel, not a scene window.
                if FloatingConversations.shared.contains(id) { store.floatConversation(id) }
                else { openWindow(id: "conversation", value: id) }
            }
        }
        // An invitation link waits in Settings > Hub.
        .onChange(of: store.pendingHubInvitation) { _, invitation in
            if invitation != nil { openSettings() }
        }
    }

    /// SwiftUI places its own sidebar toggle last in the sidebar's toolbar section, so
    /// while the sidebar is open it declares the toggle itself to let Create follow it.
    /// Column items are hidden with the sidebar; the system toggle and the window
    /// toolbar's Create return then. Toolbar spacers need macOS 26.
    private var sidebarOwnsToolbar: Bool { columnVisibility != .detailOnly }

    private var createMenu: some View {
        Menu {
            Button("New Bot", systemImage: "person.crop.circle.badge.plus") {
                store.showNewBot()
            }
            .appShortcut(.newBot)
            .disabled(!store.canCreateBot)

            Button("New Group", systemImage: "person.3.fill") {
                store.creationSheet = .group
            }
            .appShortcut(.newGroup)
            .disabled(store.agents.isEmpty)
        } label: {
            Label("Create", systemImage: "plus")
        }
        .help("Create Bot or Group")
    }

    @ToolbarContentBuilder private var sidebarToolbar: some ToolbarContent {
        if sidebarOwnsToolbar {
            ToolbarSpacer(.flexible)
            ToolbarItem {
                Button { withAnimation { columnVisibility = .detailOnly } } label: {
                    Label("Hide Sidebar", systemImage: "sidebar.leading")
                }
                .help("Hide Sidebar")
            }
            ToolbarSpacer(.fixed)
            ToolbarItem { createMenu }
        }
    }

    /// The selected conversation's input takes the keyboard, in its column or in the list's detail.
    private func focusSelectedComposer() {
        if showsColumns, let id = store.selectedConversationID { columns.focusComposer(of: id) }
        else { composerFocusRequest = UUID() }
    }

    private func content() -> some View {
        @Bindable var store = store

        return NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(focusComposer: focusSelectedComposer, focusRequest: sidebarFocusRequest)
                .toolbar(removing: sidebarOwnsToolbar ? .sidebarToggle : nil)
                .toolbar { sidebarToolbar }
                // Last: a toolbar(removing:) applied after it swallows the column width, even one removing nothing.
                .navigationSplitViewColumnWidth(min: 280, ideal: 326, max: 380)
        } detail: {
            if showsColumns { ConversationColumns(model: columns) } else { listDetail }
        }
        .navigationSplitViewStyle(.balanced)
        .background(SelectedConversationWindowHost())
        .background(MainToolbarStateUpdater(state: toolbarState, hidden: showsColumns))
        .background { SelectedConversationWallpaper(followsSelection: !showsColumns).ignoresSafeArea() }
        .onDrop(
            of: AttachmentTransfer.dropContentTypes,
            isTargeted: $isFileDropTargeted
        ) { providers in
            guard store.selectedConversation != nil, !providers.isEmpty else { return false }
            store.markConversationRead(store.selectedConversationID)
            store.importAttachments(from: providers)
            return true
        }
        .overlay {
            if isFileDropTargeted {
                WithSelectedConversation { _ in
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .padding(5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            if !sidebarOwnsToolbar {
                ToolbarItem(placement: .navigation) { createMenu }
            }

            if showsColumns { ToolbarItem(placement: .principal) { ColumnSwitcher(model: columns) } }

            // Each item reads only what it shows from toolbarState. Any change inside an item makes AppKit
            // measure it and retile the whole toolbar, so a switch that shows the same controls changes nothing.
            ToolbarItem(placement: .primaryAction) { MainToolbarInfoButton(state: toolbarState) }

            ToolbarSpacer(.flexible)
            ToolbarItem { MainToolbarPauseControl(state: toolbarState, kickRequest: $kickRequest) }
            ToolbarItem { MainToolbarCallControl(state: toolbarState) }
            ToolbarItem { MainToolbarCompanionsMenu(state: toolbarState) }

        }
        .sheet(item: $store.creationSheet) { sheet in
            switch sheet {
            case .bot:
                NewBotSheet()
                    .environment(store)
                    .noodleSheetSizing()
            case .group:
                NewGroupSheet()
                    .environment(store)
                    .noodleSheetSizing()
            }
        }
        .sheet(item: $store.agentBeingEdited) { agent in
            EditBotSheet(agent: agent)
                .environment(store)
                .noodleSheetSizing()
        }
        .sheet(item: $store.groupBeingEdited) { conversation in
            GroupInfoSheet(conversation: conversation)
                .environment(store)
                .noodleSheetSizing()
        }
        .sheet(item: $store.backgroundBeingEdited) { conversation in
            ConversationBackgroundSheet(conversation: conversation)
                .environment(store)
                .noodleSheetSizing()
        }
        .modifier(SpaceAlerts())
        // Presented by the window, not by the toolbar item that asks for it.
        .modifier(AgentKickConfirmation(store: store, request: $kickRequest))
        .sheet(isPresented: $store.editsSpaces) {
            SpaceEditorSheet()
                .environment(store)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newBot)) { _ in
            store.showNewBot()
        }
        .onReceive(NotificationCenter.default.publisher(for: .newGroup)) { _ in
            if !store.agents.isEmpty {
                store.creationSheet = .group
            }
        }
    }

    private var listDetail: some View {
        SelectedConversationDetail(composerFocusRequest: composerFocusRequest) {
            columnVisibility = .all
            sidebarFocusRequest = UUID()
        }
    }
}

/// Reads the selected conversation in a body of its own. The window around it, its toolbar included,
/// is then not rebuilt each time a message changes that conversation.
private struct WithSelectedConversation<Content: View>: View {
    @Environment(NoodleStore.self) private var store
    @ViewBuilder let content: (BotConversation) -> Content

    var body: some View {
        if let conversation = store.selectedConversation { content(conversation) }
    }
}

/// What the main window's toolbar shows for the selected conversation, kept apart from the conversation itself.
@MainActor @Observable private final class MainToolbarState {
    enum Info: Equatable { case none, editBot, groupInfo }
    enum Call: Equatable { case none, available(String, now: Bool), ongoing(UUID) }

    struct Shown: Equatable {
        var info = Info.none
        var pausedConversationID: UUID?
        var call = Call.none
        var companionsConversationID: UUID?
    }

    /// Set only when it differs: observers are told of every assignment, even of the same value.
    private(set) var shown = Shown()
    func show(_ new: Shown) { if new != shown { shown = new } }
}

/// Works out the toolbar's content outside the toolbar, which then only hears of what changes.
private struct MainToolbarStateUpdater: View {
    @Environment(NoodleStore.self) private var store
    let state: MainToolbarState
    let hidden: Bool

    var body: some View {
        let shown = hidden ? MainToolbarState.Shown() : store.selectedConversation.map(shown(for:)) ?? .init()
        Color.clear
            .accessibilityHidden(true)
            .onChange(of: shown, initial: true) { _, shown in state.show(shown) }
    }

    private func shown(for conversation: BotConversation) -> MainToolbarState.Shown {
        var shown = MainToolbarState.Shown()
        if conversation.kind == .direct, let agent = store.participants(for: conversation).first, !store.isShared(agent.id) {
            shown.info = .editBot
        } else if conversation.kind == .group {
            shown.info = .groupInfo
        }
        if store.pauseSummary(for: conversation) != nil { shown.pausedConversationID = conversation.id }
        if let call = store.voiceCalls.call, call.conversationID == conversation.id {
            shown.call = .ongoing(conversation.id)
        } else if let agent = store.voiceCallTarget(for: conversation) {
            shown.call = .available(agent.displayName, now: store.canCallNow(in: conversation))
        }
        if !store.companions(in: conversation).isEmpty { shown.companionsConversationID = conversation.id }
        return shown
    }
}

private struct MainToolbarInfoButton: View {
    @Environment(NoodleStore.self) private var store
    let state: MainToolbarState

    var body: some View {
        switch state.shown.info {
        case .editBot:
            Button {
                if let conversation = store.selectedConversation { store.agentBeingEdited = store.participants(for: conversation).first }
            } label: {
                Label("Edit Bot", systemImage: "pencil")
            }
            .help("Edit Bot")
        case .groupInfo:
            Button {
                store.groupBeingEdited = store.selectedConversation
            } label: {
                Label("Group Info", systemImage: "pencil")
            }
            .help("Group Info")
        case .none:
            EmptyView()
        }
    }
}

private struct MainToolbarPauseControl: View {
    @Environment(NoodleStore.self) private var store
    let state: MainToolbarState
    @Binding var kickRequest: AgentKickRequest?

    var body: some View {
        if let id = state.shown.pausedConversationID, let conversation = store.conversation(withID: id) {
            ConversationPauseControl(conversation: conversation, kickRequest: $kickRequest)
        }
    }
}

private struct MainToolbarCallControl: View {
    @Environment(NoodleStore.self) private var store
    let state: MainToolbarState

    var body: some View {
        switch state.shown.call {
        case .available(let name, let now):
            Button {
                if let conversation = store.selectedConversation { store.startVoiceCall(in: conversation) }
            } label: {
                Label("Call", systemImage: "phone")
            }
            .help("Call \(name)")
            // A message waits for the bot; a call needs it running now.
            .disabled(!now)
        case .ongoing(let id):
            if let conversation = store.conversation(withID: id) { VoiceCallToolbarControl(conversation: conversation) }
        case .none:
            EmptyView()
        }
    }
}

private struct MainToolbarCompanionsMenu: View {
    @Environment(NoodleStore.self) private var store
    let state: MainToolbarState

    var body: some View {
        if let id = state.shown.companionsConversationID, let conversation = store.conversation(withID: id) {
            ConversationCompanionsMenu(conversation: conversation)
        }
    }
}

private struct SelectedConversationWallpaper: View {
    @Environment(NoodleStore.self) private var store
    /// In columns each column carries its own, so the window keeps the default one.
    var followsSelection = true

    var body: some View {
        let conversation = followsSelection ? store.selectedConversation : nil
        let background = store.background(for: conversation)
        ConversationWallpaper(background: background, imageURL: conversation.flatMap {
            store.repository.backgroundImageURL(background, conversationID: $0.id)
        })
    }
}

extension NSApplication {
    /// Whether the event being handled is a click, as opposed to a key press.
    var currentEventIsClick: Bool {
        [.leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown].contains(currentEvent?.type)
    }
}

/// Tells the window registry which conversation the main window shows.
private struct SelectedConversationWindowHost: View {
    @Environment(NoodleStore.self) private var store

    var body: some View {
        ConversationWindowHost(registry: store.conversationWindows,
            conversationID: store.selectedConversationID, isMainWindow: true,
            markRead: store.markConversationRead)
    }
}

private struct SelectedConversationDetail: View {
    @Environment(NoodleStore.self) private var store
    let composerFocusRequest: UUID
    let focusSidebar: () -> Void
    @State private var focusRequest: UUID?

    var body: some View {
        if let conversation = store.selectedConversation {
            AttachmentPreviewScope(conversationID: conversation.id) { attachmentPreview in
                ChatView(conversation: conversation, attachmentPreview: attachmentPreview,
                    composerFocusRequest: focusRequest, focusSidebar: focusSidebar)
            }
            .onChange(of: composerFocusRequest) { _, request in focusRequest = request }
        } else {
            ZStack {
                Color(nsColor: .textBackgroundColor).opacity(0.28)
                    .accessibilityHidden(true)
                if store.agents.isEmpty {
                    FirstBotPrompt { store.showWelcome() }
                }
            }
        }
    }
}

#if NOODLE_DEV_HOOKS
/// Launch arguments of the development hooks, as SHA-256 digests; see Shared/LaunchChecks.
enum DevelopmentHook {
    static let browserIntegration = "f22bd67a7acd0e93b7c162f86eea51edecdc83e77c08271979f948cba83baeba"  // --browser-integration-test
    static let browserDiscovery = "34b6fe979b8f12f69dfc931336104e60b624afbfbc5b51b6a9d9b45258053a5a"  // --browser-discovery-test
    static let browserPicker = "f946359fda142c2c07f5c687991cb154fed6188b0af0ff93f77682b2be08522c"  // --browser-picker-test
    static let browserFixture = "e9f770aa4729b479fff6881b617e10f26c239e7f577120584352aa6da778c8a4"  // --browser-fixture
    static let browserFixturePort = "f78b65695a1f841162ebe135f8b6bc3e4a14a05d63b8de0744a5e065be221fa3"  // --browser-fixture-port
    static let webMCPOnly = "5fadc42340cf84b4331123681e94dffa1e71fa644d48b6dbaeaffca366a28f3d"  // --webmcp-only
    static let appletLink = "012a5f13ced3119877c3a283ffa96f725fdff5dd554906f7e15d566a0e086e09"  // --applet-link-test
    static let holdPreview = "e7e80b3aa8d8911329a7cdb1710578c33c494db824ab632362cfa40831d37229"  // --hold-preview
    static let computerIntegration = "929ce89bfb24c71e826f06240444a3ce0c44ff6108749e68574a2a658fb6e4b0"  // --computer-integration-test
    static let computerDiscovery = "cb8afdc7be7ca2bbf1fa773ff3e29a701f87b9fa5ff0829f2cee308842592486"  // --computer-discovery-test
    static let computerPicker = "9eb302341e8dcfc228f18b55db833f42b50920ce005f9aed554f4b7a1ff521af"  // --computer-picker-test
    static let computerUpdateNotice = "279a6cb632bdc55fe04c2cde06fd18eaa9e3f6c2fdc262a4f749ffe4b39b7f16"  // --computer-update-notice-test
    static let computerDownload = "241600d7fee4a10ff34b7caabd58bd674fe8d13183a01a0e50469b9081eb5585"  // --computer-download-test
    static let scenario = "fc882b0401601368259a54b753ab1714b761d5cf88bf2069356700f6a2fd580e"  // --scenario
    static let scenarioShots = "f3e02727157d7ee04aee89ffe9c56c9f6790cd3294e3a21443d0962f2ed639ff"  // --scenario-shots
    static let scenarioPicker = "41998b9aaaa37cb4b3f6a1fc5666714235669efe3190d47bf71511e4f57cc517"  // --scenario-picker
    static let scenarioSize = "3ab6e0e84b864576e7107a1f8502d0fa37e639c8ed3c973b201b159604655a6f"  // --scenario-size
    static let scenarioBenchmark = "63e110b50ffcb837f92c5221b04721f6022226032a1a8042b644c0ba78c23cad"  // --scenario-benchmark
    static let rehearse = "b7fc62f920a65a10598dc42ced62403ec5a4ddaea3b2f75aaee52d07b713629a"  // --rehearse
}
#endif
