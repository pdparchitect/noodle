import AppKit
import NoodleSettingsUI
import SwiftUI

@MainActor final class ComputerLibraryState: ObservableObject {
    static let shared = ComputerLibraryState()
    @Published var store: ComputerStore?
}

struct ComputerMenu: View {
    let delegate: ComputerAppDelegate
    @ObservedObject private var library = ComputerLibraryState.shared

    var body: some View {
        Button("Open Library") { delegate.reopenLibrary() }
        if let store = library.store {
            ComputerMenuEntries(store: store, openLibrary: delegate.reopenLibrary)
        }
        Divider()
        CompanionMenuSettingsButton()
        Button("Quit \(ComputerAppIdentity.name)") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

private struct ComputerMenuEntries: View {
    @ObservedObject var store: ComputerStore
    let openLibrary: () -> Void

    var body: some View {
        if !store.sessions.isEmpty { Divider() }
        ForEach(store.sessions) { session in
            ComputerMenuEntry(session: session) {
                store.selection = session.id
                openLibrary()
            }
        }
    }
}

private struct ComputerMenuEntry: View {
    @ObservedObject var session: ComputerSession
    let open: () -> Void
    var body: some View { Button(session.computer.name, action: open) }
}
