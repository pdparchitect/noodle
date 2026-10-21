import AppKit
import MailBridge
import MailCore
import NoodleLaunchChecks
import SwiftUI

/// Claims the app's single running copy before SwiftUI makes its delegate, which opens the mailbox list.
@main enum NoodleMailEntry {
    static func main() {
        AppInstance.claim()
        NoodleMailApp.main()
    }
}

struct NoodleMailApp: App {
    @NSApplicationDelegateAdaptor(MailAppDelegate.self) private var delegate
    var body: some Scene {
        Window(MailBuildIdentity.current.appName, id: "mailboxes") {
            MailboxesView(model: delegate.model)
                .frame(minWidth: 620, minHeight: 400)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .handlesExternalEvents(matching: [])
        .commands { MailCommands(delegate: delegate) }
    }
}

/// Hands the delegate SwiftUI's way of opening the window, which only scenes and commands receive.
private struct MailCommands: Commands {
    let delegate: MailAppDelegate
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        let action = openWindow
        let _ = delegate.openWindow = { action(id: "mailboxes") }
        CommandGroup(after: .windowArrangement) {
            Button("Mailboxes") { delegate.showMailboxes() }.keyboardShortcut("0")
        }
    }
}

@MainActor final class MailAppDelegate: NSObject, NSApplicationDelegate {
    let model: MailboxesModel
    private var server: MailConnectionServer?
    private var externalLaunch = false
    private var wantsWindow = false
    var openWindow: (() -> Void)? {
        didSet { if wantsWindow, openWindow != nil { wantsWindow = false; showMailboxes() } }
    }

    override init() {
        let library = MailboxLibrary(), secrets = MailKeychain()
        model = MailboxesModel(library: library, secrets: secrets, runtime: MailRuntime(library: library, secrets: secrets))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        startServer()
        // Noodle's background start arrives as a URL; only a person's launch opens the window.
        if notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool == true, !externalLaunch {
            DispatchQueue.main.async { if !self.externalLaunch { self.showMailboxes() } }
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        // A sandboxed Noodle starts the app with MailLaunch.backgroundURL; receiving it is enough,
        // because the server started at launch.
        externalLaunch = true
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showMailboxes(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        server = nil
        // Sign out of the mail servers politely, but never hold up quitting for long.
        let runtime = model.runtime, done = DispatchSemaphore(value: 0)
        Task.detached { await runtime.shutdown(); done.signal() }
        _ = done.wait(timeout: .now() + 2)
    }

    func showMailboxes() {
        if let openWindow { openWindow() } else { wantsWindow = true }
        NSApp.activate()
    }

    private func startServer() {
        do {
            let socket = try MailConnection.socketURL(), team = try MailConnection.signingTeam()
            let runtime = model.runtime
            server = try MailConnectionServer(socket: socket, team: team) { request, caller in
                await runtime.perform(request, caller: caller)
            }
        } catch {
            model.serverFailure = "Bots can't reach these mailboxes: \(error.localizedDescription)"
        }
    }
}
