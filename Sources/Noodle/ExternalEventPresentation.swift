import AppKit
import SwiftUI

/// Main app state belongs to one window; separate conversations use their own group.
struct MainWindowScene<Content: View>: Scene {
    @ViewBuilder var content: () -> Content
    var onOpenURL: (URL) -> Void

    var body: some Scene {
        Window(NoodleAppIdentity.name, id: "main") {
            content()
                .onOpenURL(perform: onOpenURL)
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: ["*"])
    }
}
