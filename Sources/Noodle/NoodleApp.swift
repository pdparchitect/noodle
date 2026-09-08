import AppKit
import Darwin
import SwiftUI
import NoodleCore
import UserNotifications

@main
struct NoodleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: NoodleStore

    init() {
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
        WindowGroup("Noodle") {
            RootView()
                .environment(store)
                .frame(minWidth: 980, minHeight: 670)
                .preferredColorScheme(.dark)
                .background(WindowConfiguration())
        }
        .defaultSize(width: 1160, height: 810)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .help) {
                Button("Noodle Help") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/pdparchitect/noodle")!)
                }
            }
            CommandGroup(after: .appSettings) {
                CheckForUpdatesButton()
            }
            CommandGroup(replacing: .newItem) {
                Button("New Bot") {
                    NotificationCenter.default.post(name: .newBot, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!store.canCreateBot)

                Button("New Group") {
                    NotificationCenter.default.post(name: .newGroup, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            CommandMenu("Conversation") {
                Button("Search Conversations") {
                    NotificationCenter.default.post(name: .focusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }

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
    private var attachmentPasteMonitor: Any?
    private let services = NoodleServices()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        NoodleNotifications.configure(delegate: self)
        AppUpdater.shared.start()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        attachmentPasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard event.charactersIgnoringModifiers?.lowercased() == "v",
                  modifiers == .command || modifiers == .control,
                  let store = NoodleStore.active,
                  store.composerIsFocused,
                  store.importAttachmentsFromPasteboard() else {
                return event
            }
            return nil
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Sparkle may skip the postponement callback when resuming a previous install.
        // Recheck at the actual termination boundary as well.
        if AppUpdater.shared.isInstallingUpdate && !AppUpdater.shared.canRelaunch {
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let attachmentPasteMonitor {
            NSEvent.removeMonitor(attachmentPasteMonitor)
        }
        NoodleStore.active?.stopMonitoring()
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        NoodleStore.active?.recoverAgentsAfterWake()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == "noodle" && $0.host == "shared" }) else { return }
        Task { await NoodleStore.active?.processSharedInbox() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
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
            if let rawID, let conversationID = UUID(uuidString: rawID) {
                NotificationCenter.default.post(
                    name: .openConversation,
                    object: conversationID
                )
            }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
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
        window.title = "Noodle"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        window.minSize = NSSize(width: 980, height: 670)
        window.isReleasedWhenClosed = false
    }
}

struct RootView: View {
    @Environment(NoodleStore.self) private var store
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var isFileDropTargeted = false

    var body: some View {
        @Bindable var store = store

        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 326, max: 380)
        } detail: {
            if let conversation = store.selectedConversation {
                ChatView(conversation: conversation)
            } else {
                Color(nsColor: .textBackgroundColor).opacity(0.28)
                    .accessibilityHidden(true)
            }
        }
        .navigationSplitViewStyle(.balanced)
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
            ToolbarItem(placement: .navigation) {
                Menu {
                    Button("New Bot", systemImage: "person.crop.circle.badge.plus") {
                        store.showNewBot()
                    }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!store.canCreateBot)

                    Button("New Group", systemImage: "person.3.fill") {
                        store.creationSheet = .group
                    }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(store.agents.isEmpty)
                } label: {
                    Label("Create", systemImage: "square.and.pencil")
                }
                .help("Create Bot or Group")
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
        .alert(
            "Noodle",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "An unexpected error occurred.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .newBot)) { _ in
            store.showNewBot()
        }
        .onReceive(NotificationCenter.default.publisher(for: .newGroup)) { _ in
            if !store.agents.isEmpty {
                store.creationSheet = .group
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openConversation)) { notification in
            guard let conversationID = notification.object as? UUID,
                  store.conversations.contains(where: { $0.id == conversationID }) else {
                return
            }
            store.selectedConversationID = conversationID
        }
    }
}
