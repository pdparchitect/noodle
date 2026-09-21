import AppKit
import SwiftUI
import NoodleCore

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

    private func open(_ id: UUID) {
        guard store.conversations.contains(where: { $0.id == id }) else { return }
        // A panel is outside the scene, so it opens windows through the registry.
        if isFloatingPanel { store.conversationWindows.present(id) } else { openWindow(id: "conversation", value: id) }
    }

    private var conversation: BotConversation? {
        store.conversations.first { $0.id == conversationID }
    }

    var body: some View {
        AttachmentPreviewScope(conversationID: conversationID) { preview in
            if let conversation {
                ChatView(conversation: conversation, attachmentPreview: preview,
                    composerFocusRequest: composerFocusRequest, openDirectMessage: open,
                    editAgent: { agentBeingEdited = $0 })
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
                .overlay(alignment: .top) { ConversationWindowHeaderShade() }
                .ignoresSafeArea()
            }
        }
        .background(ConversationWindowHost(registry: store.conversationWindows,
            conversationID: conversation?.id, title: conversation.map { store.title(for: $0) } ?? "Conversation",
            markRead: store.markConversationRead, openConversation: open))
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
                            Button("Edit Bot…") { agentBeingEdited = agent }
                        } else if conversation.kind == .group {
                            Button("Edit Group…") { groupBeingEdited = conversation }
                        }
                        Button("Change Background…") { backgroundBeingEdited = conversation }
                        Divider()
                        Button("Float on Top") { store.floatConversation(conversation.id) }
                    } label: {
                        Label("Conversation Info", systemImage: "slider.horizontal.3")
                    }
                    .help("Conversation Info")
                }
            }
        }
        .sheet(item: $agentBeingEdited) { agent in
            EditBotSheet(agent: agent).environment(store).noodleSheetSizing(animated: true)
        }
        .sheet(item: $groupBeingEdited) { conversation in
            GroupInfoSheet(conversation: conversation).environment(store).noodleSheetSizing()
        }
        .sheet(item: $backgroundBeingEdited) { conversation in
            ConversationBackgroundSheet(conversation: conversation).environment(store).noodleSheetSizing()
        }
        .modifier(ConversationErrorAlert())
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

struct ConversationErrorAlert: ViewModifier {
    @Environment(NoodleStore.self) private var store
    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        content.alert("Noodle", isPresented: Binding(
            get: { store.errorMessage != nil && activeState == .key },
            set: { if !$0, activeState == .key { store.errorMessage = nil } }
        )) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "An unexpected error occurred.")
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
        NotificationCenter.default.addObserver(self, selector: #selector(openRequestedConversation),
            name: .openConversation, object: nil)
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

    @objc private func openRequestedConversation(_ notification: Notification) {
        guard let id = notification.object as? UUID, !focus(id) else { return }
        let mounts = hosts.allObjects
        // A separate chat can open a notification even after the main window closes.
        let host = mounts.first(where: \.isMainWindow) ?? mounts.first
        host?.openConversation?(id)
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
        let mounts = hosts.allObjects
        if focus(conversationID, separateOnly: true) {
            NotificationCenter.default.post(name: .focusConversationComposer, object: conversationID)
            return
        }
        openSeparateWindow?(conversationID)
    }

    func focusMainWindow() {
        if let window = hosts.allObjects.first(where: \.isMainWindow)?.window { show(window) }
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
    var openConversation: ((UUID) -> Void)? = nil

    func makeNSView(context: Context) -> Probe { Probe(registry: registry) }
    func updateNSView(_ view: Probe, context: Context) {
        view.conversationID = conversationID
        view.isMainWindow = isMainWindow
        view.title = title
        view.markRead = markRead
        view.openConversation = openConversation
        DispatchQueue.main.async { [weak view] in view?.updateWindow() }
    }

    final class Probe: NSView {
        let registry: ConversationWindowRegistry
        var conversationID: UUID?
        var isMainWindow = false
        var title = NoodleAppIdentity.name
        var markRead: ((UUID?) -> Void)?
        var openConversation: ((UUID) -> Void)?
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
            window?.title = title
            window?.titlebarAppearsTransparent = true
            // A floating window is see-through; FloatingWindowLevel owns its background.
            if window?.level != .floating { window?.backgroundColor = .windowBackgroundColor }
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
