import AppKit
import SwiftUI
import NoodleCore

// Exercise the production main scene + Settings lifecycle, not an AppKit
// stand-in. Only synthetic OAuth callbacks are used; no accounts or bots run.
@MainActor private final class WindowChecks {
    static let shared = WindowChecks()
    var started = false
    var accepted = 0
    var browser: MCPBrowserAuthorization?
    var openMain: (() -> Void)?
    var openConversation: (() -> Void)?
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
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("Isolated chat window").frame(width: 450, height: 250)
            .background(WindowProbe(identifier: "test-chat"))
            .onAppear {
                WindowChecks.shared.openMain = { openWindow(id: "main") }
                WindowChecks.shared.openConversation = { openWindow(id: "conversation", value: "fixture") }
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
            try await verifyReopening(settings: settings)
            for attempt in 1...3 {
                NSApp.activate(ignoringOtherApps: true)
                settings.makeKeyAndOrderFront(nil)
                for _ in 0..<50 where NSApp.keyWindow !== settings || !NSApp.isActive {
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard NSApp.keyWindow === settings else {
                    throw MCPConnectionError.message("Settings did not gain focus before authorization")
                }
                let redirect = URL(string: attempt == 3
                    ? "com.googleusercontent.apps.noodle-window-tests:/oauth2callback"
                    : "noodle-mcp-window-tests://mcp/oauth/callback")!
                let callback = URL(string: "\(redirect)?state=state-\(attempt)&code=synthetic")!
                let browser = MCPBrowserAuthorization(timeoutDuration: .seconds(5)) { _ in
                    // The runner delivers the URL from outside the app, like a browser.
                    print("CALLBACK \(callback.absoluteString)")
                    fflush(stdout)
                    return true
                }
                WindowChecks.shared.browser = browser
                browser.captureReturnWindow()
                if attempt == 2 {
                    settings.miniaturize(nil)
                    // Finish the Dock animation before delivering the synthetic callback.
                    try await Task.sleep(for: .milliseconds(600))
                }
                _ = try await browser.authorize(
                    url: URL(string: "https://example.com/authorize?state=state-\(attempt)")!,
                    callbackURL: redirect
                )
                try await Task.sleep(for: .milliseconds(800))
                for _ in 0..<50 where NSApp.keyWindow !== settings || settings.isMiniaturized {
                    try await Task.sleep(for: .milliseconds(50))
                }
                let actualCount = NSApp.windows.filter { $0.identifier?.rawValue == "test-chat" }.count
                guard actualCount == chatCount else {
                    throw MCPConnectionError.message("Callback created another chat window: \(actualCount)")
                }
                guard NSApp.keyWindow === settings, !settings.isMiniaturized else {
                    throw MCPConnectionError.message("Callback did not focus the original Settings window (key: \(NSApp.keyWindow?.identifier?.rawValue ?? "none"), active: \(NSApp.isActive), minimized: \(settings.isMiniaturized))")
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

    @MainActor private func verifyReopening(settings: NSWindow) async throws {
        func mainWindow() throws -> NSWindow {
            let windows = NSApp.windows.filter { $0.identifier?.rawValue == "test-chat" }
            guard windows.count == 1, let window = windows.first else {
                throw MCPConnectionError.message("Expected one main window, found \(windows.count)")
            }
            guard window.isVisible, !window.isMiniaturized else {
                throw MCPConnectionError.message("Main window was not restored (visible: \(window.isVisible), minimized: \(window.isMiniaturized), active: \(NSApp.isActive))")
            }
            return window
        }
        func reopen() async throws {
            // Have the runner launch us externally. A background app asking to
            // activate itself can be refused by macOS cooperative activation.
            print("REOPEN \(UUID())")
            fflush(stdout)
            try await Task.sleep(for: .milliseconds(800))
        }

        settings.orderOut(nil)
        let original = try mainWindow()
        for _ in 0..<3 {
            try await reopen()
            guard try mainWindow() === original else {
                throw MCPConnectionError.message("Repeated launch replaced the main window")
            }
        }
        for _ in 0..<3 { WindowChecks.shared.openMain?() }
        try await Task.sleep(for: .milliseconds(500))
        _ = try mainWindow()
        print("Repeated launches and openWindow requests: one main window")

        original.miniaturize(nil)
        try await Task.sleep(for: .milliseconds(600))
        try await reopen()
        _ = try mainWindow()
        original.orderOut(nil)
        try await reopen()
        _ = try mainWindow()
        print("Minimized and hidden main window restored")

        for _ in 0..<3 {
            try mainWindow().close()
            try await reopen()
            _ = try mainWindow()
        }
        print("Close and reopen: one main window on every launch")

        WindowChecks.shared.openConversation?()
        try await Task.sleep(for: .milliseconds(500))
        try await reopen()
        _ = try mainWindow()
        let conversations = NSApp.windows.filter { $0.identifier?.rawValue == "test-conversation" && $0.isVisible }
        guard conversations.count == 1 else {
            throw MCPConnectionError.message("Separate conversation window was not preserved")
        }
        print("Separate conversation window preserved alongside the single main window")
    }
}

@main private struct WindowRoutingFixture: App {
    var body: some Scene {
        MainWindowScene {
            ChatRoot()
        } onOpenURL: { url in
            if WindowChecks.shared.browser?.receive(url) == true {
                WindowChecks.shared.accepted += 1
            }
        }
        .restorationBehavior(.disabled)
        WindowGroup("Conversation", id: "conversation", for: String.self) { _ in
            Text("Separate conversation").frame(width: 360, height: 250)
                .background(WindowProbe(identifier: "test-conversation"))
        }
        .restorationBehavior(.disabled)
        Settings { SettingsRoot() }
    }
}
