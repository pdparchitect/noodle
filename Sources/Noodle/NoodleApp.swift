import AppKit
import Darwin
import SwiftUI
import NoodleCore
import NoodleSettingsUI
import UserNotifications
#if NOODLE_DEV_HOOKS
import NoodleLaunchChecks
import os
#endif

@main
struct NoodleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: NoodleStore

    init() {
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
        if checks.contains(DevelopmentHook.computerIntegration) || checks.contains(DevelopmentHook.computerDiscovery) || checks.contains(DevelopmentHook.computerPicker) || checks.contains(DevelopmentHook.computerDocumentPreview) {
            NSApplication.shared.setActivationPolicy(.regular)
            Task { @MainActor in
                do {
                    if checks.contains(DevelopmentHook.computerDocumentPreview) { try await ComputerIntegrationTest.checkDocumentPreview() }
                    else if checks.contains(DevelopmentHook.computerPicker) { try await ComputerIntegrationTest.checkPicker() }
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
            return
        }
        #endif
        if MessengerCLI.shouldHandle() {
            let result = MessengerCLI.run()
            Self.write(result.standardOutput, to: .standardOutput)
            Self.write(result.standardError, to: .standardError)
            Darwin.exit(result.exitCode)
        }
        let store = NoodleStore()
        store.startMonitoring()
        _store = State(initialValue: store)
    }

    var body: some Scene {
        MainWindowScene {
            RootView()
                .environment(store)
                .frame(minWidth: 980, minHeight: 670)
                .preferredColorScheme(.dark)
                .background(WindowConfiguration())
        } onOpenURL: {
            store.mcp.receiveAuthorizationCallback($0)
        }
        .defaultSize(width: 1160, height: 810)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .help) {
                Button("\(NoodleAppIdentity.name) Help") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/pdparchitect/noodle")!)
                }
                BotSetupCommand(store: store)
            }
            CommandGroup(after: .appSettings) {
                CheckForUpdatesButton()
                UsageMenuButton(history: store.usage)
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
            })
            #if NOODLE_DEV_HOOKS
            ScenarioCommands()
            #endif
        }

        WindowGroup("Conversation", id: "conversation", for: UUID.self) { $conversationID in
            if let conversationID {
                ConversationWindowView(conversationID: conversationID)
                    .environment(store)
                    .frame(minWidth: 560, minHeight: 500)
                    .preferredColorScheme(.dark)
            }
        }
        .defaultSize(width: 760, height: 810)
        // Restore from the workspace even after a crash or when macOS Resume is off.
        .restorationBehavior(.disabled)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))

        Window("Usage", id: UsageView.windowID) {
            UsageView()
                .environment(store)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 860, height: 680)
        .windowResizability(.contentMinSize)
        // Opened from the app menu, next to Settings.
        .commandsRemoved()

        Settings {
            NoodleSettingsView()
                .environment(store)
                .preferredColorScheme(.dark)
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
        Task { @MainActor in
            completionHandler(
                NoodleNotifications.shouldPresentActivity ? [.banner, .sound] : []
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

        Task { @MainActor in
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

    var body: some View {
        AttachmentPreviewScope(conversationID: store.selectedConversationID) { attachmentPreview in
            content(attachmentPreview: attachmentPreview)
        }
        .task(id: store.storageReady) {
            guard store.storageReady else { return }
            store.conversationWindows.openMainWindow = { openWindow(id: "main") }
            store.conversationWindows.restoreWindows { id in
                // A conversation left floating comes back as a panel, not a scene window.
                if FloatingConversations.shared.contains(id) { store.floatConversation(id) }
                else { openWindow(id: "conversation", value: id) }
            }
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

    private func content(attachmentPreview: AttachmentPreviewController) -> some View {
        @Bindable var store = store

        return NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(focusComposer: { composerFocusRequest = UUID() }, focusRequest: sidebarFocusRequest)
                .toolbar(removing: sidebarOwnsToolbar ? .sidebarToggle : nil)
                .toolbar { sidebarToolbar }
                // Last: a toolbar(removing:) applied after it swallows the column width, even one removing nothing.
                .navigationSplitViewColumnWidth(min: 280, ideal: 326, max: 380)
        } detail: {
            if let conversation = store.selectedConversation {
                ChatView(conversation: conversation, attachmentPreview: attachmentPreview, composerFocusRequest: composerFocusRequest, focusSidebar: {
                    columnVisibility = .all
                    sidebarFocusRequest = UUID()
                })
            } else {
                ZStack {
                    Color(nsColor: .textBackgroundColor).opacity(0.28)
                        .accessibilityHidden(true)
                    if store.agents.isEmpty {
                        FirstBotPrompt { store.showsFirstBotSetup = true }
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background(ConversationWindowHost(registry: store.conversationWindows,
            conversationID: store.selectedConversationID, isMainWindow: true,
            markRead: store.markConversationRead))
        .background {
            let conversation = store.selectedConversation
            let background = store.background(for: conversation)
            ConversationWallpaper(background: background, imageURL: conversation.flatMap {
                store.repository.backgroundImageURL(background, conversationID: $0.id)
            })
            .overlay(alignment: .top) {
                ConversationWindowHeaderShade()
            }
            .ignoresSafeArea()
        }
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
            if isFileDropTargeted, store.selectedConversation != nil {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .padding(5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            if !sidebarOwnsToolbar {
                ToolbarItem(placement: .navigation) { createMenu }
            }

            ToolbarItem(placement: .primaryAction) {
                if let conversation = store.selectedConversation {
                    if conversation.kind == .direct,
                       let agent = store.participants(for: conversation).first {
                        Button {
                            store.agentBeingEdited = agent
                        } label: {
                            Label("Edit Bot", systemImage: "slider.horizontal.3")
                        }
                        .help("Edit Bot")
                    } else if conversation.kind == .group {
                        Button {
                            store.groupBeingEdited = conversation
                        } label: {
                            Label("Group Info", systemImage: "slider.horizontal.3")
                        }
                        .help("Group Info")
                    }
                }
            }

            ToolbarSpacer(.flexible)
            ToolbarItem {
                if let conversation = store.selectedConversation { ConversationCompanionsMenu(conversation: conversation) }
            }

        }
        .sheet(item: $store.creationSheet) { sheet in
            switch sheet {
            case .bot:
                NewBotSheet()
                    .environment(store)
                    .noodleSheetSizing(animated: true)
            case .group:
                NewGroupSheet()
                    .environment(store)
                    .noodleSheetSizing()
            }
        }
        .sheet(isPresented: $store.showsFirstBotSetup) {
            FirstBotSetupSheet(setup: store.harnessSetup, runtime: store.runtime)
                .environment(store)
                .noodleSheetSizing(animated: true)
        }
        .task { store.offerFirstBotSetup() }
        .sheet(item: $store.agentBeingEdited) { agent in
            EditBotSheet(agent: agent)
                .environment(store)
                .noodleSheetSizing(animated: true)
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
        .modifier(ConversationErrorAlert())
        .onReceive(NotificationCenter.default.publisher(for: .newBot)) { _ in
            store.showNewBot()
        }
        .onReceive(NotificationCenter.default.publisher(for: .newGroup)) { _ in
            if !store.agents.isEmpty {
                store.creationSheet = .group
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
    static let computerDocumentPreview = "376dcdd0ffa2dca5cf431ccd16a1a02f611c881259e6e50afd5472beb4692681"  // --computer-document-preview-test
    static let computerDownload = "241600d7fee4a10ff34b7caabd58bd674fe8d13183a01a0e50469b9081eb5585"  // --computer-download-test
    static let computerWeb = "a15d161557b60e252aff873db33a8a522c76e0fee123068f282b14e5791384d8"  // --computer-web-test
    static let scenario = "fc882b0401601368259a54b753ab1714b761d5cf88bf2069356700f6a2fd580e"  // --scenario
    static let scenarioShots = "f3e02727157d7ee04aee89ffe9c56c9f6790cd3294e3a21443d0962f2ed639ff"  // --scenario-shots
    static let scenarioPicker = "41998b9aaaa37cb4b3f6a1fc5666714235669efe3190d47bf71511e4f57cc517"  // --scenario-picker
    static let scenarioSize = "3ab6e0e84b864576e7107a1f8502d0fa37e639c8ed3c973b201b159604655a6f"  // --scenario-size
}
#endif
