import SwiftUI

/// Help > Set Up a Bot…: the first-run flow again, for anyone who closed it or wants another harness.
struct BotSetupCommand: View {
    let store: NoodleStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Set Up a Bot…") {
            // The sheet belongs to the main window, which may be closed.
            openWindow(id: "main")
            store.showsFirstBotSetup = true
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
