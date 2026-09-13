import AppKit
import SwiftUI
import NoodleCore

/// A window holds an ID, so edits and new messages always come from the shared store.
struct ConversationWindowView: View {
    @Environment(NoodleStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    let conversationID: UUID
    @State private var agentBeingEdited: AgentRecord?
    @State private var groupBeingEdited: BotConversation?
    @State private var backgroundBeingEdited: BotConversation?
    @State private var isFileDropTargeted = false

    private var conversation: BotConversation? {
        store.conversations.first { $0.id == conversationID }
    }

    var body: some View {
        AttachmentPreviewScope(conversationID: conversationID) { preview in
            if let conversation {
                ChatView(conversation: conversation, attachmentPreview: preview,
                    openDirectMessage: { openWindow(id: "conversation", value: $0) })
            } else {
                ContentUnavailableView("Conversation Unavailable", systemImage: "bubble.left",
                    description: Text("This conversation has been deleted."))
            }
        }
        .background {
            let background = store.background(for: conversation)
            ConversationWallpaper(background: background, imageURL: conversation.flatMap {
                store.repository.backgroundImageURL(background, conversationID: $0.id)
            })
            .overlay(alignment: .top) { ConversationWindowHeaderShade() }
            .ignoresSafeArea()
        }
        .background(ConversationWindowHost(registry: store.conversationWindows,
            conversationID: conversation?.id, title: conversation.map { store.title(for: $0) } ?? "Conversation",
            markRead: store.markConversationRead, openConversation: { id in
                guard store.conversations.contains(where: { $0.id == id }) else { return }
                openWindow(id: "conversation", value: id)
            }))
        .onDrop(of: AttachmentTransfer.dropContentTypes, isTargeted: $isFileDropTargeted) { providers in
            guard conversation != nil, !providers.isEmpty else { return false }
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
            ToolbarItem(placement: .principal) {
                if let conversation {
                    Text(store.title(for: conversation)).font(.headline).lineLimit(1)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if let conversation {
                    Menu {
                        if conversation.kind == .direct, let agent = store.participants(for: conversation).first {
                            Button("Edit Bot…") { agentBeingEdited = agent }
                        } else if conversation.kind == .group {
                            Button("Edit Group…") { groupBeingEdited = conversation }
                        }
                        Button("Change Background…") { backgroundBeingEdited = conversation }
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
        .onChange(of: conversation == nil) { _, missing in
            if missing { dismiss() }
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

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(openRequestedConversation),
            name: .openConversation, object: nil)
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

    @discardableResult func focus(_ conversationID: UUID) -> Bool {
        let matches = hosts.allObjects.filter { $0.conversationID == conversationID }
        guard let host = matches.first(where: { !$0.isMainWindow }) ?? matches.first,
              let window = host.window else { return false }
        show(window)
        return true
    }

    func focusMainWindow() {
        if let window = hosts.allObjects.first(where: \.isMainWindow)?.window { show(window) }
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
    var title = "Noodle"
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
        var title = "Noodle"
        var markRead: ((UUID?) -> Void)?
        var openConversation: ((UUID) -> Void)?

        init(registry: ConversationWindowRegistry) {
            self.registry = registry
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            registry.hosts.remove(self)
            guard let window else { return }
            registry.hosts.add(self)
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(markVisibleRead), name: name, object: window)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(markVisibleRead),
                name: NSApplication.didBecomeActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(closed), name: NSWindow.willCloseNotification, object: window)
            DispatchQueue.main.async { [weak self] in self?.updateWindow() }
        }
        func updateWindow() {
            window?.title = title
            window?.titlebarAppearsTransparent = true
            window?.backgroundColor = .windowBackgroundColor
            markVisibleRead()
        }
        @objc private func markVisibleRead() {
            if window?.isVisible == true { registry.hosts.add(self) }
            if let conversationID, registry.isViewing(conversationID) { markRead?(conversationID) }
        }
        @objc private func closed() { registry.hosts.remove(self) }
    }
}
