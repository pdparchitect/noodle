import AppKit
import HubCore
import NoodleCore
import SwiftUI

@main struct NoodleHubApp: App {
    @NSApplicationDelegateAdaptor(HubDelegate.self) private var delegate
    @State private var hub: Hub = {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let messenger = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/messenger")
        return Hub(root: Hub.root(applicationSupport: applicationSupport),
                   messenger: FileManager.default.isExecutableFile(atPath: messenger.path) ? messenger : nil)
    }()

    var body: some Scene {
        MenuBarExtra("Noodle Hub", systemImage: "server.rack") {
            HubMenu(hub: hub)
        }
    }
}

/// The Hub lives in the menu bar only, never in the Dock or the app switcher.
final class HubDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct HubMenu: View {
    let hub: Hub

    var body: some View {
        Section("Harnesses") {
            if hub.harnesses.isEmpty {
                Text("None found")
            } else {
                ForEach(hub.harnesses, id: \.provider) { Text($0.provider.displayName) }
            }
        }
        Divider()
        Button("Quit Noodle Hub") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
