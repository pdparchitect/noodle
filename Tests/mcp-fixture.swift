import AppKit
import SwiftUI
import Observation
import NoodleCore

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

@main enum MCPFixtureMain {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let checking = CommandLine.arguments.contains("--check")
        let live = CommandLine.arguments.contains("--check-live")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MCPChecks-" + UUID().uuidString)
        let store = try NoodleStore(root: checking ? temporary : nil)
        if checking || live {
            Task { @MainActor in
                do {
                    if live { try await checkLive(store) }
                    else {
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
            app.run()
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
        app.run()
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
