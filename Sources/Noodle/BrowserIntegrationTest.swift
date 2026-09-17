import AppKit
import BrowserBridge
import NoodleCore

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
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--browser-fixture"), i+1 < args.count,
              let browserID = UUID(uuidString: args[i+1]),
              let p = args.firstIndex(of: "--browser-fixture-port"), p+1 < args.count,
              let port = Int(args[p+1]), (1...65535).contains(port) else { throw BrowserError("Specify the isolated browser fixture ID and port.") }
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
              controller.registry.browsers.contains(where: { $0.id == browserID && $0.name == "Smoke authenticated" }) else { throw BrowserError("Signed Browser fixture is not available. Start its isolated smoke server first.") }
        try controller.assign([browserID], to: agent)
        controller.start(agents: [agent]); defer { controller.start(agents: []) }
        let workspace = repository.directory(for: agent)
        func cli(_ args: [String], expectFailure: Bool = false) async throws -> [String: Any] {
            try await Task.detached {
                let process = Process(), output = Pipe(), errors = Pipe()
                process.executableURL = workspace.appendingPathComponent(".agents/skills/browser/browser")
                process.currentDirectoryURL = workspace; process.arguments = args
                process.standardOutput = output; process.standardError = errors
                try process.run()
                let bytes = output.fileHandleForReading.readDataToEndOfFile()
                let failure = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if expectFailure {
                    guard process.terminationStatus != 0 else { throw BrowserError("Revoked CLI access succeeded.") }
                    return ["error": String(decoding: failure, as: UTF8.self)]
                }
                guard process.terminationStatus == 0 else { throw BrowserError(String(decoding: failure, as: UTF8.self)) }
                return try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
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
              let card = attachment.browser, card.reference.browser.id == browserID,
              card.reference.tabID.uuidString.lowercased() == tabID.lowercased(),
              let preview = card.reference.previewImage, NSImage(data: preview) != nil,
              try BrowserReference.read(repository.attachmentFileURL(attachment)) == card.reference else {
            throw BrowserError("CLI did not send a valid browser preview attachment.")
        }
        guard try repository.loadMessages(conversationID: createdAgent.conversation.id).last?.attachmentIDs == [attachmentID] else {
            throw BrowserError("Browser attachment was not linked to its conversation message.")
        }
        let downloads = try await cli(["downloads"] + browser)
        guard let download = (downloads["downloads"] as? [[String: Any]])?.first(where: { $0["state"] as? String == "complete" }), let id = download["id"] as? String else { throw BrowserError("Fixture download unavailable.") }
        _ = try await cli(["download"] + browser + ["--download", id, "--output", "download.txt"])
        guard try String(contentsOf: workspace.appendingPathComponent("download.txt"), encoding: .utf8) == "noodle-download-contents" else { throw BrowserError("CLI download bytes differ.") }
        _ = try await cli(["close"] + tab)
        try controller.assign([], to: agent, synchronizeWorkspace: false)
        let denied = try await cli(["tabs"] + browser, expectFailure: true)
        guard (denied["error"] as? String)?.contains("not assigned") == true else { throw BrowserError("Unexpected revocation response.") }
        _ = try await cli(["history"] + browser, expectFailure: true)
        _ = try await cli(["bookmark-add"] + browser + ["--url", "https://example.com"], expectFailure: true)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == front else { throw BrowserError("Broker operations stole focus.") }
        print("BROWSER INTEGRATION PASSED: signed peers, managed CLI, assignments/revocation, authenticated tab, history/bookmarks, uploads/downloads, screenshot, browser preview attachment, close tab, unchanged focus")
    }
}
