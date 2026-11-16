import AppKit
import SwiftUI
import NoodleBrand
import NoodleWallpaper

/// The first launch, in the main window: the wordmark writes itself, then lifts to make room
/// for setting up an account.
struct WelcomeView: View {
    @Environment(NoodleStore.self) private var store

    var body: some View {
        WordmarkWelcome(centred: true, continuesItself: true) {
            FirstBotSetupSheet(setup: store.harnessSetup, runtime: store.runtime)
        }
        // Flat: there is no title bar content for a header shade to set apart.
        .background {
            ConversationWallpaper(background: store.background(for: nil))
                .ignoresSafeArea()
        }
        .background(WelcomeCloseGuard { store.finishFirstBotSetup() })
        // The main window keeps its toolbar, and with it its shape, while the welcome fills it.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
                .sharedBackgroundVisibility(.hidden)
        }
    }
}
