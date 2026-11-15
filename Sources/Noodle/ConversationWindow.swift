import AppKit
import SwiftUI
import NoodleCore
import NoodleRuntime
import NoodleRuntimeSettings
import NoodleWallpaper

/// A window holds an ID, so edits and new messages always come from the shared store.
struct ConversationWindowView: View {
    @Environment(NoodleStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    let conversationID: UUID
    /// Hosted in a floating panel, not the scene's window: no wallpaper, toolbar or scene actions.
    var isFloatingPanel = false
    @State private var agentBeingEdited: AgentRecord?
    @State private var groupBeingEdited: BotConversation?
    @State private var backgroundBeingEdited: BotConversation?
    @State private var isFileDropTargeted = false
    @State private var composerFocusRequest: UUID?
    /// The Kick alert of this conversation's paused bot, asked for from the toolbar.
    @State private var kickRequest: AgentKickRequest?

    private func open(_ id: UUID) {
        guard store.conversations.contains(where: { $0.id == id }) else { return }
        // A panel is outside the scene, so it opens windows through the registry.
        if isFloatingPanel { store.conversationWindows.present(id) } else { openWindow(id: "conversation", value: id) }
    }

    private var conversation: BotConversation? {
        store.conversation(withID: conversationID)
    }

    var body: some View {
        AttachmentPreviewScope(conversationID: conversationID) { preview in
            if let conversation {
                ChatView(conversation: conversation, attachmentPreview: preview,
                    composerFocusRequest: composerFocusRequest, openDirectMessage: open,
                    editAgent: { agentBeingEdited = $0 }, editGroup: { groupBeingEdited = $0 })
            } else {
                ContentUnavailableView("Conversation Unavailable", systemImage: "bubble.left",
                    description: Text("This conversation has been deleted."))
            }
        }
        .background {
            if isFloatingPanel {
                FloatingWindowBackdrop().ignoresSafeArea()
            } else {
                let background = store.background(for: conversation)
                ConversationWallpaper(background: background, imageURL: conversation.flatMap {
                    store.repository.backgroundImageURL(background, conversationID: $0.id)
                })
                .ignoresSafeArea()
            }
        }
        .background(ConversationWindowHost(registry: store.conversationWindows,
            conversationID: conversation?.id, title: conversation.map { store.title(for: $0) } ?? "Conversation",
            markRead: store.markConversationRead))
        .onDrop(of: AttachmentTransfer.dropContentTypes, isTargeted: $isFileDropTargeted) { providers in
            guard conversation != nil, !providers.isEmpty else { return false }
            store.markConversationRead(conversationID)
            store.importAttachments(from: providers, into: conversationID)
            return true
        }
        .overlay {
            if isFileDropTargeted, conversation != nil {
                RoundedRectangle(cornerRadius: 15)
                    .stroke(Color.accentColor, lineWidth: 2).padding(5)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .principal) { windowTitle }
                .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .primaryAction) {
                if let conversation { ConversationPauseControl(conversation: conversation, kickRequest: $kickRequest) }
            }

            ToolbarItem(placement: .primaryAction) {
                if let conversation { VoiceCallToolbarControl(store: store, conversation: conversation) }
            }

            ToolbarItem(placement: .primaryAction) {
                if conversation != nil {
                    Button { store.returnConversationToMainWindow(conversationID) } label: {
                        Label("Show in Main Window", systemImage: "pip.exit")
                    }
                    .help("Show in Main Window")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                if let conversation, !isFloatingPanel {
                    Menu {
                        if conversation.kind == .direct, let agent = store.participants(for: conversation).first {
                            if !store.isShared(agent.id) { Button("Edit Bot…") { agentBeingEdited = agent } }
                        } else if conversation.kind == .group {
                            Button("Edit Group…") { groupBeingEdited = conversation }
                        }
                        Button("Change Background…") { backgroundBeingEdited = conversation }
                        Divider()
                        Button("Float on Top") { store.floatConversation(conversation.id) }
                    } label: {
                        Label("Conversation Info", systemImage: "ellipsis")
                    }
                    .help("Conversation Info")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                if let conversation { ConversationCompanionsMenu(conversation: conversation) }
            }
        }
        .sheet(item: $agentBeingEdited) { agent in
            EditBotSheet(agent: agent).environment(store).noodleSheetSizing()
        }
        .sheet(item: $groupBeingEdited) { conversation in
            GroupInfoSheet(conversation: conversation).environment(store).noodleSheetSizing()
        }
        .sheet(item: $backgroundBeingEdited) { conversation in
            ConversationBackgroundSheet(conversation: conversation).environment(store).noodleSheetSizing()
        }
        // Presented by the window, not by the toolbar item that asks for it.
        .modifier(AgentKickConfirmation(store: store, request: $kickRequest))
        // A window opened or brought back for a conversation starts in its input.
        .onAppear { composerFocusRequest = UUID() }
        .onReceive(NotificationCenter.default.publisher(for: .focusConversationComposer)) { notification in
            if notification.object as? UUID == conversationID { composerFocusRequest = UUID() }
        }
        .onChange(of: conversation == nil) { _, missing in
            if missing { if isFloatingPanel { FloatingConversationPanels.shared.close(conversationID) } else { dismiss() } }
        }
    }

    @ViewBuilder private var windowTitle: some View {
        if let conversation {
            HStack(spacing: 7) {
                // The name is spoken once; the picture only repeats it.
                // The dot is the only sign of life here: these windows have no sidebar row.
                ConversationStatusAvatar(conversation: conversation, size: 20, dotSize: 7, ringWidth: 1.5)
                    .accessibilityHidden(true)
                Text(store.title(for: conversation))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(store.runtimeHelp(for: conversation))
        }
    }
}

/// Shows the store's error over the window in front, on top of any sheet it has, until OK.
/// A SwiftUI alert cannot: the window under a sheet is never key, and showing an alert
/// takes key from its own window, which dismissed it before anyone saw it.
@MainActor final class StoreErrorAlert {
    private let store: NoodleStore
    private let window: () -> NSWindow?
    private let open: (URL) -> Void
    private var alert: NSAlert?
    private var keyObserver: NSObjectProtocol?

    /// The window in front, even while Noodle is in the background. None yet while the app
    /// itself is being made: NSApp is still nil then, and an error from the first load waits.
    init(store: NoodleStore, window: @escaping () -> NSWindow? = {
        guard let app = NSApp else { return nil }
        return app.keyWindow ?? app.mainWindow ?? app.orderedWindows.first { $0.isVisible && $0.canBecomeMain }
    }, open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.store = store
        self.window = window
        self.open = open
        // An error that arrived with no window open is shown once one is.
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.show(self?.store.errorMessage) }
        }
        observe()
    }

    private func observe() {
        let message = withObservationTracking { store.errorMessage } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        show(message)
    }

    private func show(_ message: String?) {
        guard let message else {
            if let sheet = alert?.window, let parent = sheet.sheetParent { parent.endSheet(sheet) }
            return
        }
        if let alert { alert.informativeText = message; return }
        guard var parent = window() else { return }
        while let sheet = parent.attachedSheet { parent = sheet }
        let alert = NSAlert()
        alert.messageText = "Noodle"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        let link = store.errorLink.flatMap { $0.message == message ? $0 : nil }
        if let link { alert.addButton(withTitle: link.title) }
        self.alert = alert
        alert.beginSheetModal(for: parent) { [weak self] response in
            guard let self else { return }
            self.alert = nil
            if let link, response == .alertSecondButtonReturn { self.open(link.url) }
            if store.errorLink?.message == alert.informativeText { store.errorLink = nil }
            if store.errorMessage == alert.informativeText { store.errorMessage = nil } else { show(store.errorMessage) }
        }
    }
}

/// Weak mounts identify real conversation windows without retaining closed scenes
/// or treating Settings, previews, and minimized windows as a viewed conversation.
@MainActor final class ConversationWindowRegistry: NSObject {
    fileprivate let hosts = NSHashTable<ConversationWindowHost.Probe>.weakObjects()
    private let session: ConversationWindowSession
    private var knownConversationIDs: Set<UUID>?
    private var hasRestoredWindows = false
    private(set) var isTerminating = false
    private var openSeparateWindow: ((UUID) -> Void)?
    /// A panel is outside every scene, so the main scene leaves its opener here.
    var openMainWindow: (() -> Void)?

    init(fileURL: URL? = nil) {
        session = ConversationWindowSession(fileURL: fileURL)
        super.init()
    }

    func retainConversations(_ ids: Set<UUID>) {
        knownConversationIDs = ids
        session.retainConversations(ids)
    }

    func restoreWindows(openWindow: @escaping (UUID) -> Void) {
        // The main window's host selects in place, so panels and floating need the scene's own opener.
        openSeparateWindow = openWindow
        guard !hasRestoredWindows else { return }
        hasRestoredWindows = true
        for id in session.frames.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            // The main window can display this same conversation independently.
            guard !hosts.allObjects.contains(where: { !$0.isMainWindow && $0.conversationID == id }) else { continue }
            openWindow(id)
        }
    }

    func prepareForTermination() {
        // AppKit closing windows during Quit must not look like explicit closes.
        isTerminating = true
    }

    fileprivate func checkpoint(_ host: ConversationWindowHost.Probe) {
        guard !isTerminating, !host.isClosed, !host.isMainWindow, !host.isRestoringFrame,
              let id = host.conversationID, let window = host.window,
              knownConversationIDs?.contains(id) != false else { return }
        if host.restoredConversationID != id {
            host.restoredConversationID = id
            if let frame = session.frames[id] {
                host.isRestoringFrame = true
                window.setFrame(from: frame)
                window.setFrame(window.constrainFrameRect(window.frame, to: window.screen ?? NSScreen.main), display: false)
                host.isRestoringFrame = false
            }
        }
        // Keep the normal frame while a window is full screen.
        guard !window.styleMask.contains(.fullScreen) else { return }
        session.save(frame: window.frameDescriptor, for: id)
    }

    fileprivate func closed(_ host: ConversationWindowHost.Probe) {
        hosts.remove(host)
        guard !isTerminating, !host.isMainWindow, let id = host.conversationID,
              !hosts.allObjects.contains(where: { !$0.isMainWindow && $0.conversationID == id }) else { return }
        session.remove(id)
    }

    func isViewing(_ conversationID: UUID) -> Bool {
        NSApp.isActive && hosts.allObjects.contains {
            $0.conversationID == conversationID && $0.window.map {
                $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
            } == true
        }
    }

    @discardableResult func focus(_ conversationID: UUID, separateOnly: Bool = false) -> Bool {
        let matches = hosts.allObjects.filter { $0.conversationID == conversationID && !(separateOnly && $0.isMainWindow) }
        guard let host = matches.first(where: { !$0.isMainWindow }) ?? matches.first,
              let window = host.window else { return false }
        show(window)
        host.markRead?(conversationID)
        return true
    }

    /// The conversation a window shows, so menu commands can act on the key window's chat.
    func conversationID(in window: NSWindow?) -> UUID? {
        guard let window else { return nil }
        return hosts.allObjects.first { !$0.isClosed && $0.window === window }?.conversationID
    }

    /// Closes the conversation's normal separate window and returns the frame it had.
    func closeSeparateWindow(_ conversationID: UUID) -> NSRect? {
        guard let window = hosts.allObjects.first(where: {
            !$0.isMainWindow && $0.conversationID == conversationID && !($0.window is FloatingConversationPanel)
        })?.window else { return nil }
        let frame = window.frame
        window.close()
        return frame
    }

    func hasSavedFrame(_ conversationID: UUID) -> Bool { session.frames[conversationID] != nil }

    /// Opens or raises the conversation's separate window and puts the caret in its input.
    func present(_ conversationID: UUID) {
        if focus(conversationID, separateOnly: true) {
            NotificationCenter.default.post(name: .focusConversationComposer, object: conversationID)
            return
        }
        openSeparateWindow?(conversationID)
    }

    /// Raises the main window, opening it again if it was closed.
    func showMainWindow() {
        if let window = hosts.allObjects.first(where: { $0.isMainWindow && !$0.isClosed })?.window { show(window) }
        else { openMainWindow?() }
    }

    private func show(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct ConversationWindowHost: NSViewRepresentable {
    let registry: ConversationWindowRegistry
    let conversationID: UUID?
    var isMainWindow = false
    var title = NoodleAppIdentity.name
    let markRead: (UUID?) -> Void

    func makeNSView(context: Context) -> Probe { Probe(registry: registry) }
    func updateNSView(_ view: Probe, context: Context) {
        view.conversationID = conversationID
        view.isMainWindow = isMainWindow
        view.title = title
        view.markRead = markRead
        DispatchQueue.main.async { [weak view] in view?.updateWindow() }
    }

    final class Probe: NSView {
        let registry: ConversationWindowRegistry
        var conversationID: UUID?
        var isMainWindow = false
        var title = NoodleAppIdentity.name
        var markRead: ((UUID?) -> Void)?
        fileprivate var restoredConversationID: UUID?
        fileprivate var isRestoringFrame = false
        fileprivate var isClosed = false
        private var interactionMonitor: Any?
        private static let interactionEvents: NSEvent.EventTypeMask = [
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .keyDown, .scrollWheel, .magnify, .smartMagnify, .rotate, .swipe, .pressure
        ]

        init(registry: ConversationWindowRegistry) {
            self.registry = registry
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoringInteractions()
            NotificationCenter.default.removeObserver(self)
            registry.hosts.remove(self)
            guard let window else { return }
            isClosed = false
            restoredConversationID = nil
            registry.hosts.add(self)
            interactionMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.interactionEvents) { [weak self] event in
                self?.handleInteraction(event)
                return event
            }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(markVisibleRead), name: name, object: window)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(markVisibleRead),
                name: NSApplication.didBecomeActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(closed), name: NSWindow.willCloseNotification, object: window)
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(checkpoint), name: name, object: window)
            }
            DispatchQueue.main.async { [weak self] in self?.updateWindow() }
        }
        func handleInteraction(_ event: NSEvent) {
            guard !isClosed, let window, let conversationID,
                  event.window === window,
                  Self.interactionEvents.contains(NSEvent.EventTypeMask(rawValue: 1 << event.type.rawValue)) else { return }
            // Input in this window is direct evidence of reading. Activation and
            // occlusion notifications can still describe the previous app state.
            markRead?(conversationID)
        }
        private func stopMonitoringInteractions() {
            if let interactionMonitor { NSEvent.removeMonitor(interactionMonitor) }
            interactionMonitor = nil
        }
        deinit { if let interactionMonitor { NSEvent.removeMonitor(interactionMonitor) } }
        func updateWindow() {
            guard !isClosed else { return }
            // Each runs on every update, and setting even the same value makes AppKit redo the titlebar and its toolbar.
            if let window {
                if window.title != title { window.title = title }
                if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
                // A floating window is see-through; FloatingWindowLevel owns its background.
                if window.level != .floating, window.backgroundColor != .windowBackgroundColor { window.backgroundColor = .windowBackgroundColor }
            }
            checkpoint()
            markVisibleRead()
        }
        @objc private func checkpoint() { registry.checkpoint(self) }
        @objc private func markVisibleRead() {
            guard !isClosed else { return }
            if window?.isVisible == true { registry.hosts.add(self) }
            if let conversationID, registry.isViewing(conversationID) { markRead?(conversationID) }
        }
        @objc private func closed() {
            isClosed = true
            stopMonitoringInteractions()
            registry.closed(self)
        }
    }
}

extension Notification.Name {
    /// The object is the conversation ID whose separate or floating window should return to its input.
    static let focusConversationComposer = Notification.Name("Noodle.focusConversationComposer")
}
