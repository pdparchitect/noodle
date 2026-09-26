import AppKit
import HubCore
import HubLink
import NoodleLaunchChecks
import NoodleRuntimeSettings
import SwiftUI

/// "Noodle Hub Dev" in development builds, so they are told apart from a released Hub running beside them.
let hubAppName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Noodle Hub"

/// Claims the app's single running copy before SwiftUI makes its delegate, which opens its data.
@main enum NoodleHubEntry {
    static func main() {
        AppInstance.claim()
        NoodleHubApp.main()
    }
}

struct NoodleHubApp: App {
    @NSApplicationDelegateAdaptor(HubDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra(hubAppName, systemImage: "server.rack") {
            HubMenu(hub: delegate.settings.hub)
        }
        Window("Usage", id: UsageView.windowID) {
            UsageView(history: delegate.settings.hub.usage, agents: delegate.settings.agents)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 860, height: 680)
        .windowResizability(.contentMinSize)
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
        // Development builds listen on their own port so they can run beside a released Hub.
        let port = (Bundle.main.object(forInfoDictionaryKey: "NoodleHubLinkPort") as? String).flatMap(UInt16.init)
        return HubSettingsHost(hub: Hub(root: Hub.root(applicationSupport: applicationSupport),
            messenger: FileManager.default.isExecutableFile(atPath: messenger.path) ? messenger : nil,
            linkPort: port ?? LinkEndpoint.defaultPort, router: SystemRouterPortMapper()))
    }()

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        HubUpdater.shared.start()
        do { try settings.hub.bots.start() }
        catch { NSLog("Noodle Hub could not start its bots: \(error.localizedDescription)") }
        Task { await settings.hub.link.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        settings.hub.link.stop()
        settings.hub.bots.stop()
    }
}

struct HubMenu: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    let hub: Hub

    var body: some View {
        Button("Usage…") {
            hub.usage.agentFilter = nil
            NSApp.activate()
            openWindow(id: UsageView.windowID)
        }
        .keyboardShortcut("u", modifiers: [.command, .shift])
        Button("Settings…") {
            // A menu bar app is never frontmost on its own; bring Settings forward.
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit \(hubAppName)") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
