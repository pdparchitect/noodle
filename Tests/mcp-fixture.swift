import AppKit
import SwiftUI
import Observation
import NoodleCore
import NoodleMCP

// Real MCP views/controller, with a minimal store and no harness runtime.
@MainActor @Observable final class NoodleStore {
    let mcp: MCPController
    let repository: WorkspaceRepository
    let agent: AgentRecord
    init(root override: URL? = nil) throws {
        let root = override ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MCPFixture", isDirectory: true)
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/messenger")
        repository = WorkspaceRepository(rootURL: root, launcherExecutableURL: helper)
        try repository.prepare()
        agent = try repository.loadAgents().first ?? repository.createAgent(named: "MCP Test Bot").agent
        mcp = MCPController(repository: repository)
        mcp.start(agents: [agent])
        if mcp.registry.connections.isEmpty {
            try mcp.save(MCPConnectionRecord(name: "Notion Test", endpoint: URL(string: "https://mcp.notion.com/mcp")!,
                                            description: "Isolated Notion integration test"))
        }
    }
}

struct MCPFixtureView: View {
    let store: NoodleStore
    @State private var selected: Set<UUID> = []
    @State private var result = "No agents or harnesses run in this window."
    @State private var testing = false
    var body: some View {
        VStack(spacing: 0) {
            MCPSettingsView().environment(store)
            Divider()
            MCPAssignmentPicker(controller: store.mcp, selectedIDs: $selected).padding(20)
            HStack {
                Text(result).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                Button("Test CLI Tool Discovery") { testCLI() }.disabled(testing || selected.isEmpty)
            }.padding(20)
        }.frame(width: 620)
            .onAppear { selected = store.mcp.selectedIDs(for: store.agent) }
            .onChange(of: store.mcp.signInStage) { _, stage in
                try? stage.write(to: store.repository.rootURL.appendingPathComponent("test-status.txt"), atomically: true, encoding: .utf8)
            }
            .onChange(of: store.mcp.errors) { _, errors in
                try? errors.values.joined(separator: "\n").write(to: store.repository.rootURL.appendingPathComponent("test-error.txt"), atomically: true, encoding: .utf8)
            }
            .onChange(of: selected) { _, ids in
                do { try store.mcp.assign(ids, to: store.agent) }
                catch { result = error.localizedDescription }
            }
    }
    private func testCLI() {
        guard let id = selected.first else { return }
        testing = true; result = "Discovering tools through the bundled CLI…"
        let workspace = store.repository.directory(for: store.agent)
        Task {
            do {
                let count = try await Task.detached {
                    let process = Process()
                    process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/mcpshim")
                    process.currentDirectoryURL = workspace
                    process.arguments = ["tools", "--connection", id.uuidString]
                    let output = Pipe()
                    process.standardOutput = output
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0,
                          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let tools = object["tools"] as? [[String: Any]] else {
                        throw MCPConnectionError.message("CLI discovery failed. Check the connection's status above.")
                    }
                    return tools.count
                }.value
                result = "Passed: CLI → Noodle → MCP returned \(count) tools. No tools were executed."
            } catch { result = error.localizedDescription }
            testing = false
        }
    }
}

@MainActor private final class MCPFixtureDelegate: NSObject, NSApplicationDelegate {
    let controller: MCPController
    init(controller: MCPController) { self.controller = controller }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { controller.receiveAuthorizationCallback(url) }
    }
}

@main enum MCPFixtureMain {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let checking = CommandLine.arguments.contains("--check")
        let live = CommandLine.arguments.contains("--check-live")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MCPChecks-" + UUID().uuidString)
        let store = try NoodleStore(root: checking ? temporary : nil)
        let delegate = MCPFixtureDelegate(controller: store.mcp)
        app.delegate = delegate
        if checking || live {
            Task { @MainActor in
                do {
                    if live { try await checkLive(store) }
                    else {
                        try await checkBrowserAuthorization()
                        try await checkBridge(store)
                        try? FileManager.default.removeItem(at: temporary)
                        print("MCP native broker checks passed: unassigned rejection, missing sign-in, assigned skill and removal")
                    }
                    exit(0)
                } catch {
                    if checking { try? FileManager.default.removeItem(at: temporary) }
                    print("MCP native broker check failed: \(error.localizedDescription)")
                    exit(1)
                }
            }
            withExtendedLifetime(delegate) { app.run() }
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 470),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "MCP Integration Tests — Isolated Data"
        window.contentView = NSHostingView(rootView: MCPFixtureView(store: store))
        window.center(); window.makeKeyAndOrderFront(nil)
        app.activate()
        if CommandLine.arguments.contains("--connect"), let connection = store.mcp.registry.connections.first {
            Task { @MainActor in store.mcp.connect(connection) }
        }
        withExtendedLifetime(delegate) { app.run() }
    }
    @MainActor private static func checkBrowserAuthorization() async throws {
        let redirect = URL(string: "noodle-mcp-tests://mcp/oauth/callback")!
        let authorization = URL(string: "https://example.com/authorize?state=first-state")!
        var opened: [URL] = []
        let browser = MCPBrowserAuthorization { opened.append($0); return true }
        let login = Task { try await browser.authorize(url: authorization, callbackURL: redirect) }
        while opened.isEmpty { await Task.yield() }
        guard opened == [authorization] else { throw MCPConnectionError.message("Wrong browser URL") }
        for raw in [
            "noodle://shared?state=first-state",
            "noodle-mcp-tests://mcp/wrong?state=first-state&code=code",
            "noodle-mcp-tests://mcp/oauth/callback?state=wrong&code=code",
            "noodle-mcp-tests://mcp/oauth/callback?state=first-state&state=first-state&code=code",
            "noodle-mcp-tests://user@mcp/oauth/callback?state=first-state&code=code",
            "noodle-mcp-tests://mcp/oauth/callback?state=first-state&code=code#fragment"
        ] {
            guard !browser.receive(URL(string: raw)!) else { throw MCPConnectionError.message("Invalid callback consumed sign-in") }
        }
        let callback = URL(string: redirect.absoluteString + "?state=first-state&code=code")!
        guard browser.receive(callback), try await login.value == callback, !browser.receive(callback) else {
            throw MCPConnectionError.message("Valid callback did not complete exactly once")
        }
        let cancelled = Task { try await browser.authorize(url: authorization, callbackURL: redirect) }
        while opened.count < 2 { await Task.yield() }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw MCPConnectionError.message("Cancellation was ignored") }
        catch is CancellationError {}
        guard !browser.receive(callback) else { throw MCPConnectionError.message("Cancelled callback remained active") }
        let nextAuthorization = URL(string: "https://example.com/authorize?state=second-state")!
        let next = Task { try await browser.authorize(url: nextAuthorization, callbackURL: redirect) }
        while opened.count < 3 { await Task.yield() }
        guard !browser.receive(callback) else { throw MCPConnectionError.message("Stale callback consumed new sign-in") }
        let nextCallback = URL(string: redirect.absoluteString + "?state=second-state&error=access_denied")!
        guard browser.receive(nextCallback), try await next.value == nextCallback else {
            throw MCPConnectionError.message("Provider rejection was not returned to OAuth validation")
        }
        let failed = MCPBrowserAuthorization { _ in false }
        do {
            _ = try await failed.authorize(url: authorization, callbackURL: redirect)
            throw MCPServiceError.invalidCallback
        } catch is MCPConnectionError {}
        let timed = MCPBrowserAuthorization(timeoutDuration: .milliseconds(10)) { _ in true }
        do {
            _ = try await timed.authorize(url: authorization, callbackURL: redirect)
            throw MCPConnectionError.message("Timeout was ignored")
        } catch MCPServiceError.timedOut {}
        guard !timed.receive(callback) else { throw MCPConnectionError.message("Expired callback remained active") }
        print("Normal-browser OAuth checks passed: opener, state/target validation, replay rejection, cancellation, timeout and open failure")
    }
    @MainActor private static func checkLive(_ store: NoodleStore) async throws {
        guard let connection = store.mcp.registry.connections.first(where: {
            $0.name == "Notion Test" && $0.endpoint.absoluteString == "https://mcp.notion.com/mcp"
        }) else { throw MCPConnectionError.message("Connect Notion Test in the isolated fixture first.") }
        let previous = store.mcp.selectedIDs(for: store.agent)
        try store.mcp.assign([connection.id], to: store.agent)
        defer { try? store.mcp.assign(previous, to: store.agent) }
        let workspace = store.repository.directory(for: store.agent)
        let count = try await Task.detached {
            let process = Process()
            process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/mcpshim")
            process.currentDirectoryURL = workspace
            process.arguments = ["tools", "--connection", connection.id.uuidString]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.standardError
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tools = object["tools"] as? [[String: Any]], !tools.isEmpty else {
                throw MCPConnectionError.message("Live CLI discovery failed.")
            }
            return tools.count
        }.value
        print("Live Notion CLI → broker → official MCP client passed: \(count) tools; no tools executed.")
    }
    @MainActor private static func checkBridge(_ store: NoodleStore) async throws {
        guard let connection = store.mcp.registry.connections.first else { fatalError("Missing fixture connection") }
        func run() async throws -> String {
            let workspace = store.repository.directory(for: store.agent)
            return try await Task.detached {
                let process = Process()
                process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/mcpshim")
                process.currentDirectoryURL = workspace
                process.arguments = ["tools", "--connection", connection.id.uuidString]
                let error = Pipe()
                process.standardOutput = FileHandle.nullDevice
                process.standardError = error
                try process.run()
                let data = error.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 1 else { throw MCPConnectionError.message("Expected a denied CLI request.") }
                return String(decoding: data, as: UTF8.self)
            }.value
        }
        guard try await run().contains("not assigned") else { throw MCPConnectionError.message("Unassigned request was not rejected.") }
        try store.mcp.assign([connection.id], to: store.agent)
        let folder = store.repository.directory(for: store.agent).appendingPathComponent(".agents/skills/" + connection.skillName)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("SKILL.md").path),
              FileManager.default.isExecutableFile(atPath: folder.appendingPathComponent("mcpshim").path) else {
            throw MCPConnectionError.message("Assigned skill or CLI is missing.")
        }
        guard try await run().contains("Reconnect") else { throw MCPConnectionError.message("Unsigned-in request did not reach the credential gate.") }
        try store.mcp.assign([], to: store.agent)
        guard !FileManager.default.fileExists(atPath: folder.appendingPathComponent("SKILL.md").path),
              try await run().contains("not assigned") else { throw MCPConnectionError.message("Removed access remained usable.") }
    }
}
