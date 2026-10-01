import SwiftUI

/// Help > Set Up a Bot…: the welcome again, for anyone who closed it or wants another harness.
struct BotSetupCommand: View {
    let store: NoodleStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Welcome") {
            // The welcome fills the main window, which may be closed.
            openWindow(id: "main")
            store.showWelcome()
        }
        .disabled(!store.storageReady)
    }
}

/// Shown in the empty main window until the first bot exists.
struct FirstBotPrompt: View {
    let setUp: () -> Void

    var body: some View {
        Button("Set Up Your First Bot", action: setUp)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(32)
    }
}
