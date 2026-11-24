import ComputerEngine
import NoodleSettingsUI
import SwiftUI

struct ComputerImageUpdateButton: View {
    @ObservedObject var session: ComputerSession
    var action: () -> Void

    var body: some View {
        Button("Upgrade", systemImage: "arrow.down.circle", action: action)
            .disabled(session.phase.busy)
            .help("Upgrade the computer image while keeping your files and local changes")
    }
}

extension View {
    // Attach the confirmation to the persistent row/sheet, not the transient
    // context-menu button, so dismissing the menu doesn't discard the alert.
    func computerImageUpdateConfirmation(store: ComputerStore, session: ComputerSession,
                                         isPresented: Binding<Bool>) -> some View {
        modifier(ComputerImageUpgradePresenter(store: store, session: session, confirming: isPresented))
    }
}

/// Asks first, then upgrades in the upgrade's own window.
private struct ComputerImageUpgradePresenter: ViewModifier {
    let store: ComputerStore
    @ObservedObject var session: ComputerSession
    @Binding var confirming: Bool
    @State private var upgrading = false

    func body(content: Content) -> some View {
        content
            .alert("Upgrade \(session.computer.name)?", isPresented: $confirming) {
                Button("Cancel", role: .cancel) {}
                Button("Upgrade") { upgrading = true }
            } message: {
                Text("Download the current image and keep your files and local changes. Files you changed take precedence over files in the new image. A running computer will stop during the upgrade and restart afterward.")
            }
            .sheet(isPresented: $upgrading) { ComputerImageUpgradeSheet(store: store, session: session) }
    }
}

/// One image upgrade, run apart from its window so nothing closing around it cancels it; only Cancel Upgrade does.
@MainActor final class ComputerImageUpgrade: ObservableObject {
    enum Stage: Equatable { case upgrading, finished(String), failed(String), closed }
    @Published private(set) var stage = Stage.upgrading
    private let session: ComputerSession
    /// Runs the upgrade and returns why it failed, if it did.
    private let perform: @MainActor () async -> String?
    private var started = false

    init(session: ComputerSession, perform: @escaping @MainActor () async -> String?) {
        self.session = session
        self.perform = perform
    }

    func run() async {
        guard !started else { return }
        started = true
        let failure = await perform()
        // A cancelled upgrade ends with neither, and needs nothing more.
        stage = failure.map(Stage.failed) ?? session.updateResult.map(Stage.finished) ?? .closed
    }
}

struct ComputerImageUpgradeSheet: View {
    let store: ComputerStore
    @ObservedObject var session: ComputerSession
    @StateObject private var upgrade: ComputerImageUpgrade
    @Environment(\.dismiss) private var dismiss

    init(store: ComputerStore, session: ComputerSession) {
        self.store = store
        self.session = session
        _upgrade = StateObject(wrappedValue: ComputerImageUpgrade(session: session) {
            await store.updateImage(session)
            // Shown here, where the upgrade was asked for, and not again by the app.
            defer { store.error = nil }
            return store.error
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Upgrade \(session.computer.name)").font(.headline)
            switch upgrade.stage {
            case .finished(let message), .failed(let message):
                Text(message).foregroundStyle(.secondary).textSelection(.enabled)
            case .upgrading, .closed:
                ProgressView(value: session.updateProgress)
                Text(session.updateStatus ?? "Upgrading the computer image…").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Spacer()
                switch upgrade.stage {
                case .finished, .failed:
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                case .upgrading, .closed:
                    Button("Cancel Upgrade") { store.cancelImageUpdate(session) }
                }
            }
        }
        .padding(20)
        .frame(width: 380).noodleSheetSizing()
        .interactiveDismissDisabled()
        // Unstructured, so the upgrade outlives this window if whatever presents it goes away.
        .onAppear { Task { await upgrade.run() } }
        .onChange(of: upgrade.stage) { _, stage in if stage == .closed { dismiss() } }
    }
}
