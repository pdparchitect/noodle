import AppKit
import Darwin
import SwiftUI
import NoodleCore
import NoodleSettingsUI
import UserNotifications

@main
struct NoodleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: NoodleStore

    init() {
        if CommandLine.arguments.contains("--browser-integration-test") || CommandLine.arguments.contains("--browser-discovery-test") || CommandLine.arguments.contains("--browser-picker-test") {
            NSApplication.shared.setActivationPolicy(.accessory)
            Task { @MainActor in
                do {
                    if CommandLine.arguments.contains("--browser-picker-test") { try await BrowserPickerIntegrationTest.run() }
                    else if CommandLine.arguments.contains("--browser-discovery-test") { try await BrowserIntegrationTest.checkDiscovery() }
                    else { try await BrowserIntegrationTest.run() }
                    Darwin.exit(0)
                }
                catch { print("BROWSER INTEGRATION FAILED: \(error.localizedDescription)"); Darwin.exit(1) }
            }
            NSApplication.shared.run()
            Darwin.exit(1)
        }
        if CommandLine.arguments.contains("--applet-link-test") {
            NSApplication.shared.setActivationPolicy(.regular)
            Task { @MainActor in
                do { try await AppletLinkIntegrationTest.run(); Darwin.exit(0) }
                catch { print("APPLET LINK INTEGRATION FAILED: \(error.localizedDescription)"); Darwin.exit(1) }
            }
            NSApplication.shared.run()
            Darwin.exit(1)
        }
        if CommandLine.arguments.contains("--computer-integration-test") || CommandLine.arguments.contains("--computer-discovery-test") || CommandLine.arguments.contains("--computer-picker-test") || CommandLine.arguments.contains("--computer-document-preview-test") {
            NSApplication.shared.setActivationPolicy(.regular)
            Task { @MainActor in
                do {
                    if CommandLine.arguments.contains("--computer-document-preview-test") { try await ComputerIntegrationTest.checkDocumentPreview() }
                    else if CommandLine.arguments.contains("--computer-picker-test") { try await ComputerIntegrationTest.checkPicker() }
                    else if CommandLine.arguments.contains("--computer-discovery-test") { try await ComputerIntegrationTest.checkDiscovery() }
                    else { try await ComputerIntegrationTest.run() }
                    Darwin.exit(0)
                }
                catch { print("COMPUTER INTEGRATION FAILED: \(error.localizedDescription)"); Darwin.exit(1) }
            }
            NSApplication.shared.run()
            Darwin.exit(1)
        }
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

            ConversationCommands {
                NotificationCenter.default.post(name: .focusSearch, object: nil)
            }
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
        NSApp.setActivationPolicy(.regular)
        NoodleStore.active?.updateDockBadge()
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        NoodleNotifications.configure(delegate: self)
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
        let rawID = response.notification.request.content.userInfo[
            NoodleNotifications.conversationIDKey
        ] as? String

        Task { @MainActor in
            if let rawID, let conversationID = UUID(uuidString: rawID),
               NoodleStore.active?.conversationWindows.focus(conversationID) != true {
                NotificationCenter.default.post(
                    name: .openConversation,
                    object: conversationID
                )
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
    static let openConversation = Notification.Name("Noodle.openConversation")
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
            store.conversationWindows.restoreWindows { openWindow(id: "conversation", value: $0) }
        }
    }

    /// SwiftUI places its own sidebar toggle last in the sidebar's toolbar section, so
    /// while the sidebar is open it declares the toggle itself to let Create follow it.
    /// Column items are hidden with the sidebar; the system toggle and the window
    /// toolbar's Create return then. Toolbar spacers need macOS 26.
    private var sidebarOwnsToolbar: Bool {
        if #available(macOS 26.0, *) { return columnVisibility != .detailOnly }
        return false
    }

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
        if #available(macOS 26.0, *), sidebarOwnsToolbar {
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
                .navigationSplitViewColumnWidth(min: 280, ideal: 326, max: 380)
                .toolbar(removing: sidebarOwnsToolbar ? .sidebarToggle : nil)
                .toolbar { sidebarToolbar }
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
            markRead: store.markConversationRead, openConversation: { id in
                guard store.conversations.contains(where: { $0.id == id }) else { return }
                store.selectedConversationID = id
                store.conversationWindows.focusMainWindow()
            }))
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
