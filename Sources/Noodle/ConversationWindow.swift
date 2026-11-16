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
        .conversationFileDrop(isEnabled: { conversation != nil }) { providers in
            store.markConversationRead(conversationID)
            store.importAttachments(from: providers, into: conversationID)
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

extension StoreErrorAlert {
    /// Noodle's store error, with the button that fixes it when there is one.
    convenience init(store: NoodleStore, window: @escaping @MainActor () -> NSWindow? = StoreErrorAlert.frontWindow,
                     open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.init(title: "Noodle", message: { store.errorMessage }, clear: { store.errorMessage = nil },
                  link: { message in store.errorLink.flatMap { $0.message == message ? ($0.title, $0.url) : nil } },
                  linkUsed: { message in if store.errorLink?.message == message { store.errorLink = nil } },
                  window: window, open: open)
    }
}

extension FloatingConversationPanels {
    /// Noodle's panels, each showing the conversation as its own window does.
    static let shared = FloatingConversationPanels(floating: .shared,
        isTerminating: { NoodleStore.active?.conversationWindows.isTerminating == true },
        toggleCall: { NoodleStore.active?.toggleVoiceCall(in: $0) }) { id, commands in
        guard let store = NoodleStore.active else { return NSView() }
        let view = NSHostingView(rootView: ConversationWindowView(conversationID: id, isFloatingPanel: true)
            .environment(store).environment(\.floatingPanelCommands, commands))
        // The panel owns its size; the chat must not resize it to fit content.
        view.sizingOptions = []
        return view
    }
}

extension NoodleStore {
    /// Opens the conversation as a floating panel, replacing its normal separate window if one is open.
    func floatConversation(_ id: UUID, from frame: NSRect? = nil) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        conversationWindows.float(id, in: .shared, from: frame)
    }

    /// Opens the conversation in a normal separate window, docking its floating panel if one is open.
    func dockConversation(_ id: UUID) {
        conversationWindows.dock(id, panels: .shared)
    }

    /// Shows the conversation in the main window and closes its separate window or floating panel.
    func returnConversationToMainWindow(_ id: UUID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        conversationWindows.returnToMainWindow(id, panels: .shared) { selectedConversationID = $0 }
    }
}
