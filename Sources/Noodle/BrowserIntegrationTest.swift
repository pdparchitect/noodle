#if NOODLE_DEV_HOOKS
import AppKit
import BrowserBridge
import NoodleBrowserTools
import NoodleCore
import NoodleLaunchChecks

/// Explicit fixture mode, with a fresh repository and an explicitly identified
/// fake browser. Does not load the user's Noodle workspace or launch agents.
@MainActor enum BrowserIntegrationTest {
    static func checkDiscovery() async throws {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserDiscovery-" + UUID().uuidString)
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = BrowserController(repository: repository)
        await controller.refresh(launchIfNeeded: true)
        guard controller.available else { throw BrowserError(controller.failure ?? "Browser did not start.") }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == front else { throw BrowserError("Starting Browser stole focus.") }
        print("BROWSER DISCOVERY PASSED: matching companion found and started without changing application focus")
    }
    static func run() async throws {
        setbuf(stdout, nil)
        let checks = LaunchChecks.current
        // "auto" finds the fixture by name, for hosts that cannot read the companion's container.
        guard let fixture = checks.value(after: DevelopmentHook.browserFixture),
              fixture == "auto" || UUID(uuidString: fixture) != nil,
              let port = checks.value(after: DevelopmentHook.browserFixturePort).flatMap({ Int($0) }),
              (1...65535).contains(port) else { throw BrowserError("Specify the isolated browser fixture ID and port.") }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserBroker-" + UUID().uuidString)
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
        let repository = WorkspaceRepository(rootURL: root, launcherExecutableURL: helpers.appendingPathComponent("messenger"))
        try repository.prepare(); defer { try? FileManager.default.removeItem(at: root) }
        let createdAgent = try repository.createAgent(named: "Browser fixture")
        let agent = createdAgent.agent
        // Keep the signed fixture away from a user's running companion socket.
        let socket = try BrowserConnection.socketURL().deletingLastPathComponent().appendingPathComponent("t.sock")
        let team = try BrowserConnection.signingTeam()
        let controller = BrowserController(repository: repository) { request in
            try await BrowserConnection.call(request, socket: socket, team: team)
        }
        await controller.refresh()
        guard controller.available, controller.registry.browsers.count == 2,
              let browserID = controller.registry.browsers.first(where: { $0.name == "Smoke authenticated" })?.id,
              fixture == "auto" || UUID(uuidString: fixture) == browserID else { throw BrowserError("Signed Browser fixture is not available. Start its isolated smoke server first.") }
        // The same pieces the app wires together, with the provider pointed at the fixture's
        // socket instead of running inside the extension against a user's companion.
        let assignments = ToolAssignmentStore(), registry = ToolProviderRegistry()
        let staging = socket.deletingLastPathComponent()
        try registry.register(BrowserToolProvider(stagingRoot: { staging }) { try await BrowserConnection.call($0, socket: socket, team: team) })
        let broker = ToolBridgeBroker(registry: registry, host: .repository(repository) { assignments.assignments(for: $0) }) { assignments.assignments(for: $0) }
        controller.onAssignmentsChange = { assignments.replace("browser", with: $0); broker.synchronizeSkills() }
        try controller.assign([browserID], to: agent)
        let workspace = repository.directory(for: agent)
        try broker.start(agents: [ToolBridgeAgent(id: agent.id, workspace: workspace)]); defer { broker.stop() }
        func cli(_ args: [String], expectFailure: Bool = false) async throws -> [String: Any] {
            try await Task.detached {
                let process = Process(), output = Pipe(), errors = Pipe()
                process.executableURL = workspace.appendingPathComponent(".agents/skills/messenger/messenger")
                // "webmcp list" and "webmcp call" are the tools webmcp-list and webmcp-call.
                let tool = args[0] == "webmcp" ? ["webmcp-" + args[1]] + args.dropFirst(2) : args
                process.currentDirectoryURL = workspace; process.arguments = ["tool", "browser"] + tool
                process.standardOutput = output; process.standardError = errors
                try process.run()
                let bytes = output.fileHandleForReading.readDataToEndOfFile()
                let failure = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                // A tool result carries its JSON in structuredContent; a tool error its message in content.
                let result = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
                let message = ((result?["content"] as? [[String: Any]])?.first)?["text"] as? String
                if expectFailure {
                    guard process.terminationStatus != 0 else { throw BrowserError("Revoked CLI access succeeded.") }
                    if let structured = result?["structuredContent"] as? [String: Any] { return structured }
                    return ["error": message ?? String(decoding: failure, as: UTF8.self)]
                }
                guard process.terminationStatus == 0, let structured = result?["structuredContent"] as? [String: Any] else {
                    throw BrowserError(message ?? String(decoding: failure, as: UTF8.self))
                }
                return structured
            }.value
        }
        let list = try await cli(["list"])
        guard (list["browsers"] as? [[String: Any]])?.count == 1 else { throw BrowserError("CLI exposed unassigned browsers.") }
        let browser = ["--browser", browserID.uuidString]
        let opened = try await cli(["open"] + browser + ["--url", "http://127.0.0.1:\(port)"])
        guard let tabID = opened["tabID"] as? String else { throw BrowserError("CLI did not return a tab.") }
        let tab = browser + ["--tab", tabID]
        var ready = false
        for _ in 0..<80 {
            let value = try? await cli(["eval"] + tab + ["--text", "return document.readyState==='complete' && !!document.querySelector('#file');"])
            if value?["value"] as? Bool == true { ready = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard ready else { throw BrowserError("Browser fixture page did not load.") }
        let auth = try await cli(["eval"] + tab + ["--text", "return (await (await fetch('/auth-state')).json()).authenticated;"])
        guard auth["value"] as? Bool == true else { throw BrowserError("Broker tab did not share the signed-in profile.") }
        if !checks.contains(DevelopmentHook.webMCPOnly) {
            let moved = try await cli(["move"] + tab + ["--target", "#click"])
            guard (moved["pointer"] as? [String: Any])?["visible"] as? Bool == true else { throw BrowserError("CLI pointer state missing.") }
            let hovered = try await cli(["eval"] + tab + ["--text", "return document.querySelector('#click').matches(':hover');"])
            guard hovered["value"] as? Bool == true else { throw BrowserError("CLI hover did not reach the page.") }
            _ = try await cli(["click"] + tab + ["--target", "#click", "--count", "2"])
            let clicked = try await cli(["eval"] + tab + ["--text", "return document.querySelector('#click').dataset.count;"])
            guard clicked["value"] as? String == "2" else { throw BrowserError("CLI double click did not reach the page.") }
            _ = try await cli(["mouse-reset"] + tab)
            let pointerStatus = try await cli(["status"] + tab)
            guard (pointerStatus["pointer"] as? [String: Any])?["visible"] as? Bool == false else { throw BrowserError("CLI pointer reset failed.") }
            print("PASS managed CLI pointer move, native hover, double click and reset")
            let history = try await cli(["history"] + browser + ["--query", "history-marker", "--limit", "1", "--offset", "0"])
            guard history["totalCount"] as? Int == 1, (history["history"] as? [[String: Any]])?.count == 1 else { throw BrowserError("CLI history query failed.") }
            let created = try await cli(["bookmark-add"] + browser + ["--url", "http://127.0.0.1:\(port)/cli-bookmark", "--title", "CLI bookmark"])
            guard let record = created["bookmark"] as? [String: Any], let bookmarkID = record["id"] as? String else { throw BrowserError("CLI did not create bookmark.") }
            _ = try await cli(["bookmark-update"] + browser + ["--bookmark", bookmarkID, "--title", "Edited CLI bookmark"])
            let saved = try await cli(["bookmarks"] + browser + ["--query", "Edited CLI bookmark"])
            guard saved["totalCount"] as? Int == 1, (saved["bookmarks"] as? [[String: Any]])?.first?["id"] as? String == bookmarkID else { throw BrowserError("CLI bookmark edit/search failed.") }
            _ = try await cli(["bookmark-remove"] + browser + ["--bookmark", bookmarkID])
            let removed = try await cli(["bookmarks"] + browser + ["--query", "Edited CLI bookmark"])
            guard removed["totalCount"] as? Int == 0 else { throw BrowserError("CLI bookmark removal failed.") }
            let invalid = try await cli(["history"] + browser + ["--limit", "201"], expectFailure: true)
            guard (invalid["error"] as? String)?.contains("limit") == true else { throw BrowserError("CLI did not validate pagination.") }
            let data = Data("broker-upload-contents".utf8)
            try data.write(to: workspace.appendingPathComponent("upload.txt"))
            _ = try await cli(["upload"] + tab + ["--target", "#file", "--source", "upload.txt"])
            let uploaded = try await cli(["eval"] + tab + ["--text", "return await document.querySelector('#file').files[0].text();"])
            guard uploaded["value"] as? String == String(decoding: data, as: UTF8.self) else { throw BrowserError("CLI upload bytes differ.") }
            _ = try await cli(["screenshot"] + tab + ["--output", "capture.png"])
            guard NSImage(contentsOf: workspace.appendingPathComponent("capture.png")) != nil else { throw BrowserError("CLI screenshot transfer failed.") }
            let presented = try await cli(["present"] + tab + ["--conversation", createdAgent.conversation.id.uuidString, "--message", "Browser fixture page"])
            guard let attachmentID = (presented["attachmentID"] as? String).flatMap(UUID.init(uuidString:)),
                  let attachment = try repository.loadAttachments(conversationID: createdAgent.conversation.id).first(where: { $0.id == attachmentID }),
                  case .browser(let id, let tab)? = attachment.companion, id == browserID,
                  tab?.uuidString.lowercased() == tabID.lowercased(),
                  let preview = attachment.card?.image, NSImage(data: preview) != nil else {
                throw BrowserError("CLI did not send a valid browser preview attachment.")
            }
            guard try repository.loadMessages(conversationID: createdAgent.conversation.id).last?.attachmentIDs == [attachmentID] else {
                throw BrowserError("Browser attachment was not linked to its conversation message.")
            }
            let downloads = try await cli(["downloads"] + browser)
            guard let download = (downloads["downloads"] as? [[String: Any]])?.first(where: { $0["state"] as? String == "complete" }), let id = download["id"] as? String else { throw BrowserError("Fixture download unavailable.") }
            _ = try await cli(["download"] + browser + ["--download", id, "--output", "download.txt"])
            guard try String(contentsOf: workspace.appendingPathComponent("download.txt"), encoding: .utf8) == "noodle-download-contents" else { throw BrowserError("CLI download bytes differ.") }
        }
        _ = try await cli(["navigate"] + tab + ["--url", "http://127.0.0.1:\(port)/webmcp"])
        var webMCPReady = false
        for _ in 0..<80 {
            let value = try? await cli(["eval"] + tab + ["--text", "return location.pathname==='/webmcp' && await window.webMCPReady===true;"])
            if value?["value"] as? Bool == true { webMCPReady = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard webMCPReady else { throw BrowserError("CLI WebMCP fixture did not load.") }
        let discovered = try await cli(["webmcp", "list"] + tab)
        guard let webTools = (discovered["value"] as? [String: Any])?["tools"] as? [[String: Any]],
              let echoID = webTools.first(where: { $0["name"] as? String == "echo" })?["id"] as? String else { throw BrowserError("CLI did not discover WebMCP tools.") }
        try Data(#"{"text":"CLI file arguments","count":2}"#.utf8).write(to: workspace.appendingPathComponent("arguments.json"))
        let called = try await cli(["webmcp", "call"] + tab + ["--tool", echoID, "--args-file", "arguments.json"])
        guard let result = (called["value"] as? [String: Any])?["result"] as? [String: Any],
              result["authenticated"] as? Bool == true, result["text"] as? String == "CLI file arguments" else { throw BrowserError("CLI WebMCP call lost arguments or authentication.") }
        try Data("const tools=await document.modelContext.getTools(); return JSON.parse(await document.modelContext.executeTool(tools.find(t=>t.name==='echo'), {text:'script file'}));".utf8).write(to: workspace.appendingPathComponent("workflow.js"))
        let scripted = try await cli(["eval"] + tab + ["--file", "workflow.js"])
        guard (scripted["value"] as? [String: Any])?["text"] as? String == "script file" else { throw BrowserError("CLI eval script file did not use the shared WebMCP registry.") }
        _ = try await cli(["webmcp", "call"] + tab + ["--tool", echoID, "--args", "[]"], expectFailure: true)
        let invalidSchema = try await cli(["webmcp", "call"] + tab + ["--tool", echoID, "--args", #"{"text":"bad","count":0}"#], expectFailure: true)
        guard ((invalidSchema["value"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String == "INVALID_ARGUMENTS" else { throw BrowserError("CLI WebMCP error did not preserve its JSON code.") }
        let mailboxFiles = try FileManager.default.contentsOfDirectory(atPath: workspace.appendingPathComponent(ToolBroker.path).path)
        guard !mailboxFiles.contains(where: { $0.hasSuffix(".request") || $0.hasSuffix(".response") }) else { throw BrowserError("Failed WebMCP CLI call left request files behind.") }
        _ = try await cli(["webmcp", "call"] + tab + ["--tool", echoID, "--args-file", "../outside.json"], expectFailure: true)
        print("PASS WebMCP managed CLI discovery, JSON invocation, workspace argument files, structured failure exit and authenticated execution")
        _ = try await cli(["close"] + tab)
        try controller.assign([], to: agent, synchronizeWorkspace: false)
        let denied = try await cli(["tabs"] + browser, expectFailure: true)
        guard (denied["error"] as? String)?.contains("not assigned") == true else { throw BrowserError("Unexpected revocation response.") }
        _ = try await cli(["history"] + browser, expectFailure: true)
        _ = try await cli(["bookmark-add"] + browser + ["--url", "https://example.com"], expectFailure: true)
        _ = try await cli(["webmcp", "list"] + tab, expectFailure: true)
        _ = try await cli(["webmcp", "call"] + tab + ["--tool", echoID], expectFailure: true)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == front else { throw BrowserError("Broker operations stole focus.") }
        if checks.contains(DevelopmentHook.webMCPOnly) {
            print("BROWSER WEBMCP INTEGRATION PASSED: signed peers, managed CLI, assignments/revocation, argument files, authenticated execution, close tab, unchanged focus")
        } else {
            print("BROWSER INTEGRATION PASSED: signed peers, managed CLI, assignments/revocation, authenticated tab, history/bookmarks, uploads/downloads, screenshot, browser preview attachment, WebMCP, close tab, unchanged focus")
        }
    }
}
#endif
