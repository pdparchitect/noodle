import SwiftUI

struct ComputerImageUpdateButton: View {
    @ObservedObject var session: ComputerSession
    var action: () -> Void

    var body: some View {
        Button("Update", systemImage: "arrow.down.circle", action: action)
            .disabled(session.phase.busy)
            .help("Update the computer image while keeping your files and local changes")
    }
}

extension View {
    // Attach the confirmation to the persistent row/sheet, not the transient
    // context-menu button, so dismissing the menu doesn't discard the alert.
    func computerImageUpdateConfirmation(store: ComputerStore, session: ComputerSession,
                                         isPresented: Binding<Bool>) -> some View {
        alert("Update \(session.computer.name)?", isPresented: isPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Update") { Task { await store.updateImage(session) } }
        } message: {
            Text("Download the current image and keep your files and local changes. Files you changed take precedence over files in the new image. A running computer will stop during the update and restart afterward.")
        }
    }
}
