import AppKit
import Observation
import SwiftUI
import NoodleRuntimeSettings

/// Companions are usually installed or removed while Noodle is in the background,
/// so their availability is looked up again whenever Noodle becomes active.
@MainActor @Observable final class CompanionAppMenu {
    private var installed: Set<CompanionApp>
    @ObservationIgnored private let discover: @MainActor () -> [CompanionApp: CompanionAppInstallation]
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(discover: @escaping @MainActor () -> [CompanionApp: CompanionAppInstallation] = { CompanionApp.installedApps() },
         notificationCenter: NotificationCenter = .default) {
        self.discover = discover
        installed = Set(discover().keys)
        observer = notificationCenter.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                  object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func isAvailable(_ app: CompanionApp) -> Bool { installed.contains(app) }

    func refresh() {
        let current = Set(discover().keys)
        if current != installed { installed = current }
    }
}

/// Opens Noodle Browser, Computer and Applet from the Window menu; those not installed are dimmed.
struct CompanionAppCommands: Commands {
    let store: NoodleStore
    @State private var menu = CompanionAppMenu()

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Divider()
            ForEach(CompanionApp.allCases) { app in
                Button(app.name) {
                    Task { @MainActor in
                        do { try await store.openCompanionLibrary(app) }
                        catch { NSApp.presentError(error) }
                    }
                }
                .disabled(!menu.isAvailable(app))
            }
        }
    }
}
