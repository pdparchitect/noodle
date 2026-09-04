import AppKit
import SwiftUI
import SuperBotCore

@main
struct SuperBotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = SuperBotStore()

    var body: some Scene {
        WindowGroup("SuperBot") {
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
            CommandGroup(replacing: .newItem) {
                Button("New Bot") {
                    NotificationCenter.default.post(name: .newBot, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)

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
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}

extension Notification.Name {
    static let newBot = Notification.Name("SuperBot.newBot")
    static let newGroup = Notification.Name("SuperBot.newGroup")
    static let focusSearch = Notification.Name("SuperBot.focusSearch")
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
        window.title = "SuperBot"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        window.minSize = NSSize(width: 980, height: 670)
        window.isReleasedWhenClosed = false
    }
}

struct RootView: View {
    @Environment(SuperBotStore.self) private var store
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var store = store

        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 326, max: 380)
        } detail: {
            if let conversation = store.selectedConversation {
                ChatView(conversation: conversation)
            } else {
                WelcomeView()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Menu {
                    Button("New Bot", systemImage: "person.crop.circle.badge.plus") {
                        store.creationSheet = .bot
                    }
                    .keyboardShortcut("n", modifiers: .command)

                    Button("New Group", systemImage: "person.3.fill") {
                        store.creationSheet = .group
                    }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(store.agents.count < 2)
                } label: {
                    Label("Create", systemImage: "square.and.pencil")
                }
                .help("Create Bot or Group")
            }

            ToolbarItem(placement: .principal) {
                if let conversation = store.selectedConversation {
                    ConversationToolbarLabel(conversation: conversation)
                } else {
                    Text("SuperBot").font(.headline)
                }
            }

            ToolbarItem(placement: .primaryAction) {
                HarnessStatusLabel()
            }
        }
        .sheet(item: $store.creationSheet) { sheet in
            switch sheet {
            case .bot:
                NewBotSheet()
                    .environment(store)
            case .group:
                NewGroupSheet()
                    .environment(store)
            }
        }
        .sheet(item: $store.agentBeingRenamed) { agent in
            RenameBotSheet(agent: agent)
                .environment(store)
        }
        .alert(
            "SuperBot",
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
            store.creationSheet = .bot
        }
        .onReceive(NotificationCenter.default.publisher(for: .newGroup)) { _ in
            if store.agents.count >= 2 {
                store.creationSheet = .group
            }
        }
    }
}

private struct HarnessStatusLabel: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(.orange).frame(width: 7, height: 7)
            Text("Harnesses not connected")
                .font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.45), in: Capsule())
        .help("Harness locations have not been configured")
    }
}
