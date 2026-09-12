import AppKit
import AppletBridge
import NoodleCore
import QuickLookUI

/// Explicit signed-app fixture; it never opens the user's repository or starts real agents.
@MainActor enum AppletLinkIntegrationTest {
    static func run() async throws {
        setbuf(stdout, nil)
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("NoodletLinks-Test-\(UUID())")
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
        let repository = WorkspaceRepository(rootURL: root, launcherExecutableURL: helpers.appendingPathComponent("messenger"))
        try repository.prepare()
        defer { try? manager.removeItem(at: root) }
        let author = try repository.createAgent(named: "Fixture Author").agent
        let participant = try repository.createAgent(named: "Fixture Participant").agent
        let group = try repository.createGroup(named: "Fixture", participantIDs: [author.id, participant.id], existingAgents: [author, participant])
        let controller = AppletController(repository: repository)
        controller.start(agents: [author, participant])
        defer { controller.start(agents: []) }
        let source = repository.directory(for: author).appendingPathComponent("Hello.noodlet")
        try manager.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"version":1,"title":"Noodlet link preview","runtime":"html","entry":"index.html","network":false}"#.utf8)
            .write(to: source.appendingPathComponent("noodlet.json"))
        try Data("""
            <html><style>body{font:24px -apple-system;background:#182d37;color:white;padding:60px}button{font:inherit;padding:12px}</style>
            <h1>Noodlet link preview</h1><p>This package was resolved directly from its ID.</p>
            <button id="play" onclick="this.textContent='Interactive preview works'">Try the preview</button></html>
            """.utf8).write(to: source.appendingPathComponent("index.html"))
        func cli(_ args: [String], agent: AgentRecord) async throws -> AppletResponse {
            let cwd = repository.directory(for: agent)
            return try await Task.detached {
                let process = Process(), output = Pipe()
                process.executableURL = helpers.appendingPathComponent("noodlet")
                process.currentDirectoryURL = cwd; process.arguments = args
                process.standardOutput = output; process.standardError = FileHandle.standardError
                try process.run()
                let bytes = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let response = try JSONDecoder().decode(AppletResponse.self, from: bytes).checked()
                guard process.terminationStatus == 0 else { throw AppletError("CLI failed.") }
                return response
            }.value
        }
        let registered = try await cli(["validate", source.path], agent: author)
        guard let id = registered.noodletID, let url = registered.url, registered.sessionID == nil else {
            throw AppletError("Validation failed to register without running.")
        }
        let info = try await cli(["info", "--path", source.path], agent: author)
        guard info.noodletID == id else { throw AppletError("Info lost the source identity.") }
        do {
            _ = try await cli(["info", "--id", url.absoluteString], agent: participant)
            throw AppletError("Unauthorized ID resolved.")
        } catch let error as AppletError where error.message.contains("unavailable to this caller") {}
        let send = MessengerCLI.run(arguments: ["messenger", "--agent-directory", repository.directory(for: author).path,
            "--send", "--conversation", group.id.uuidString, "--attach", url.absoluteString], environment: [:])
        guard send.exitCode == 0 else { throw AppletError(send.standardError) }
        let shared = ["--id", url.absoluteString, "--conversation", group.id.uuidString]
        let resolved = try await cli(["info"] + shared, agent: participant)
        guard resolved.noodletID == id, resolved.previewBookmark == nil else { throw AppletError("Shared access failed.") }
        let access = try await controller.resolvePreview(url)
        defer { try? manager.removeItem(at: access.url) }
        guard access.url.path == registered.path,
              try String(contentsOf: access.url.appendingPathComponent("index.html"), encoding: .utf8).contains("Try the preview") else {
            throw AppletError("Signed cross-sandbox package access failed.")
        }
        print("PASS: real CLI registration, stable info, ownership, Messenger webloc, shared participant access, signed preview bookmark")
        let opened = try await cli(["open", "--mode", "headless"] + shared, agent: participant)
        guard opened.sessionID != nil else { throw AppletError("Shared run failed.") }
        let capture = repository.directory(for: participant).appendingPathComponent("capture.png")
        _ = try await cli(["screenshot", "--output", capture.path] + shared, agent: participant)
        guard NSImage(contentsOf: capture) != nil else { throw AppletError("Shared capture transfer failed.") }
        _ = try await cli(["close"] + shared, agent: participant)
        print("PASS: shared headless run, screenshot transfer, close")
        let foreground = try await controller.openNoodlet(url)
        guard foreground.state == "running", foreground.sessionID != nil else {
            throw AppletError("Attachment did not open a live noodlet.")
        }
        let reopened = try await controller.openNoodlet(url)
        guard reopened.sessionID == foreground.sessionID else { throw AppletError("Repeated open created another instance.") }
        _ = try await cli(["click", "--target", "#play"] + shared, agent: participant)
        let interaction = try await cli(["eval", "--text", "return {visible:document.visibilityState,button:document.querySelector('#play').textContent};"] + shared, agent: participant)
        guard let value = interaction.value, value.contains("visible"), value.contains("Interactive preview works"),
              !value.contains("hidden") else { throw AppletError("Opened noodlet was not visible and interactive.") }
        _ = try await cli(["eval", "--text", "await noodle.storage.set('link-test', 'saved');"] + shared, agent: participant)
        guard !QLPreviewPanel.sharedPreviewPanelExists() || QLPreviewPanel.shared()?.isVisible != true else {
            throw AppletError("Opening a noodlet displayed Quick Look.")
        }
        print("PASS: attachment opens a visible live noodlet, reuses its window, and responds to interaction without Quick Look")
        if CommandLine.arguments.contains("--hold-preview") { try await Task.sleep(for: .seconds(30)) }
        _ = try await cli(["close"] + shared, agent: participant)
        _ = try await controller.openNoodlet(url)
        let stored = try await cli(["eval", "--text", "return await noodle.storage.get('link-test');"] + shared, agent: participant)
        guard stored.value?.contains("saved") == true else { throw AppletError("Saved noodlet data did not survive reopening.") }
        _ = try await cli(["close"] + shared, agent: participant)
        print("PASS: live noodlet retains saved data after closing and reopening")
        print("APPLET LINK INTEGRATION PASSED")
    }
}
