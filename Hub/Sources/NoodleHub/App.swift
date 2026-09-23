import AppKit
import HubCore
import NoodleCore
import SwiftUI

@main struct NoodleHubApp: App {
    @NSApplicationDelegateAdaptor(HubDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Noodle Hub", systemImage: "server.rack") {
            HubMenu(hub: delegate.hub)
        }
    }
}

/// The Hub lives in the menu bar only, never in the Dock or the app switcher.
@MainActor final class HubDelegate: NSObject, NSApplicationDelegate {
    let hub: Hub = {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let messenger = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/messenger")
        return Hub(root: Hub.root(applicationSupport: applicationSupport),
                   messenger: FileManager.default.isExecutableFile(atPath: messenger.path) ? messenger : nil)
    }()

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        HubUpdater.shared.start()
        Task { await hub.startServer() }
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
        Section("Clients") {
            if let port = hub.serverPort {
                Text("Listening on 127.0.0.1:\(String(port))")
                Button("Copy Access Token") {
                    guard let token = try? hub.accessToken() else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(token, forType: .string)
                }
            } else {
                Text(hub.serverError.map { "Not listening: \($0)" } ?? "Starting…")
            }
        }
        Divider()
        HubCheckForUpdatesButton()
        Button("Quit Noodle Hub") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
