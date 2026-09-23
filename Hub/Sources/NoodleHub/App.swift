import AppKit
import HubCore
import SwiftUI

@main struct NoodleHubApp: App {
    @NSApplicationDelegateAdaptor(HubDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Noodle Hub", systemImage: "server.rack") {
            HubMenu()
        }
        Settings {
            HubSettingsView(host: delegate.settings)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
    }
}

/// The Hub lives in the menu bar only, never in the Dock or the app switcher.
@MainActor final class HubDelegate: NSObject, NSApplicationDelegate {
    let settings: HubSettingsHost = {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let messenger = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/messenger")
        return HubSettingsHost(hub: Hub(root: Hub.root(applicationSupport: applicationSupport),
            messenger: FileManager.default.isExecutableFile(atPath: messenger.path) ? messenger : nil))
    }()

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        HubUpdater.shared.start()
    }
}

struct HubMenu: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") {
            // A menu bar app is never frontmost on its own; bring Settings forward.
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit Noodle Hub") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
