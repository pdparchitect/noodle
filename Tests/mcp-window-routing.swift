import AppKit
import SwiftUI
import NoodleCore

// Exercise the real SwiftUI WindowGroup + Settings lifecycle, not an AppKit
// stand-in. Only synthetic OAuth callbacks are used; no accounts or bots run.
@MainActor private final class WindowChecks {
    static let shared = WindowChecks()
    var started = false
    var accepted = 0
    var browser: MCPBrowserAuthorization?
}

@MainActor private final class CallbackDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard CommandLine.arguments.contains("--baseline") else { return }
        for url in urls where WindowChecks.shared.browser?.receive(url) == true {
            WindowChecks.shared.accepted += 1
        }
    }
}

private struct WindowProbe: NSViewRepresentable {
    let identifier: String
    func makeNSView(context: Context) -> Probe { Probe(identifier: identifier) }
    func updateNSView(_ view: Probe, context: Context) {}
    final class Probe: NSView {
        let windowID: String
        init(identifier: String) { windowID = identifier; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.identifier = NSUserInterfaceItemIdentifier(windowID)
        }
    }
}

private struct ChatRoot: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Text("Isolated chat window").frame(width: 450, height: 250)
            .background(WindowProbe(identifier: "test-chat"))
            .onAppear {
                guard !WindowChecks.shared.started else { return }
                WindowChecks.shared.started = true
                DispatchQueue.main.async { openSettings() }
            }
    }
}

private struct SettingsRoot: View {
    var body: some View {
        Text("Isolated MCP settings").frame(width: 360, height: 160)
            .background(WindowProbe(identifier: "test-settings"))
            .task { await verifyCallbacks() }
    }

    @MainActor private func verifyCallbacks() async {
        do {
            try await Task.sleep(for: .milliseconds(600))
            guard let settings = NSApp.windows.first(where: { $0.identifier?.rawValue == "test-settings" }) else {
                throw MCPConnectionError.message("Settings window was not created")
            }
            let chatCount = NSApp.windows.filter { $0.identifier?.rawValue == "test-chat" }.count
            guard chatCount == 1 else { throw MCPConnectionError.message("Expected one initial chat window") }
            for attempt in 1...3 {
                settings.makeKeyAndOrderFront(nil)
                let scheme = "noodle-mcp-window-tests"
                let redirect = URL(string: "\(scheme)://mcp/oauth/callback")!
                let callback = URL(string: "\(redirect)?state=state-\(attempt)&code=synthetic")!
                let browser = MCPBrowserAuthorization(timeoutDuration: .seconds(5)) { _ in
                    // Send through Launch Services so SwiftUI also receives the event.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NSWorkspace.shared.open(callback)
                    }
                    return true
                }
                WindowChecks.shared.browser = browser
                browser.captureReturnWindow()
                if attempt == 2 { settings.miniaturize(nil) }
                _ = try await browser.authorize(
                    url: URL(string: "https://example.com/authorize?state=state-\(attempt)")!,
                    callbackURL: redirect
                )
                try await Task.sleep(for: .milliseconds(800))
                let actualCount = NSApp.windows.filter { $0.identifier?.rawValue == "test-chat" }.count
                guard actualCount == chatCount else {
                    throw MCPConnectionError.message("Callback created another chat window: \(actualCount)")
                }
                guard NSApp.keyWindow === settings, !settings.isMiniaturized else {
                    throw MCPConnectionError.message("Callback did not focus the original Settings window")
                }
                guard !browser.receive(callback) else {
                    throw MCPConnectionError.message("Duplicate callback was accepted")
                }
                print("Callback \(attempt): one chat window, original Settings focused")
            }
            guard WindowChecks.shared.accepted == 3 else {
                throw MCPConnectionError.message("Callback delivery count was wrong")
            }
            print("MCP SwiftUI window routing checks passed")
            fflush(stdout)
            exit(0)
        } catch {
            print("MCP SwiftUI window routing FAILED: \(error.localizedDescription)")
            fflush(stdout)
            exit(1)
        }
    }
}

@main private struct WindowRoutingFixture: App {
    @NSApplicationDelegateAdaptor(CallbackDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("MCP Window Routing Tests") {
            if CommandLine.arguments.contains("--baseline") {
                ChatRoot()
            } else {
                ChatRoot().reuseWindowForExternalEvents { url in
                    if WindowChecks.shared.browser?.receive(url) == true {
                        WindowChecks.shared.accepted += 1
                    }
                }
            }
        }
        .handlesExternalEvents(matching: ["*"])
        Settings { SettingsRoot() }
    }
}
