#if NOODLE_DEV_HOOKS
import AppKit
import AppletBridge
import NoodleAppletTools
import NoodleRuntime
import NoodleCore
import NoodleLaunchChecks
import NoodletRuntime
import QuickLookUI

/// Explicit signed-app fixture; it never opens the user's repository or starts real agents.
@MainActor enum AppletLinkIntegrationTest {
    static func run() async throws {
        setbuf(stdout, nil)
        try await runOnThisMac()
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("NoodletLinks-Test-\(UUID())")
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
        let repository = WorkspaceRepository(rootURL: root, launcherExecutableURL: helpers.appendingPathComponent("messenger"))
        try repository.prepare()
        defer { try? manager.removeItem(at: root) }
        let author = try repository.createAgent(named: "Fixture Author").agent
        let participant = try repository.createAgent(named: "Fixture Participant").agent
        let group = try repository.createGroup(named: "Fixture", participantIDs: [author.id, participant.id], existingAgents: [author, participant])
        let controller = AppletController()
        controller.start(agents: [author, participant])
        defer { controller.start(agents: []) }
        let source = repository.directory(for: author).appendingPathComponent("Hello.\(AppletBuildIdentity.current.fileExtension)")
        try manager.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"version":1,"title":"Noodlet link preview","runtime":"html","entry":"index.html","network":false}"#.utf8)
            .write(to: source.appendingPathComponent("noodlet.json"))
        try Data("""
            <html><style>body{font:24px -apple-system;background:#182d37;color:white;padding:60px}button{font:inherit;padding:12px}</style>
            <h1>Noodlet link preview</h1><p>This package was resolved directly from its ID.</p>
            <button id="play" onclick="this.textContent='Interactive preview works'">Try the preview</button></html>
            """.utf8).write(to: source.appendingPathComponent("index.html"))
        // Bots' requests go as Noodle sends them: through the tool broker and the applet tool.
        let registry = ToolProviderRegistry()
        try registry.register(AppletToolProvider { try await controller.tool($0) })
        let granted: ToolAssignments = [AppletToolGrant.kind: [AppletToolGrant.id]]
        let host = ToolHostServices.repository(repository) { _ in granted }
        func cli(_ args: [String], agent: AgentRecord) async throws -> AppletResponse {
            var arguments: [String: Any] = [:]
            var rest = args.dropFirst()
            while let flag = rest.popFirst() {
                arguments[String(flag.dropFirst(2))] = rest.popFirst()
            }
            let request = ToolBridgeRequest(session: "", action: .call, provider: "applet", tool: args[0],
                                            arguments: try JSONSerialization.data(withJSONObject: arguments))
            let result = try await ToolBroker.perform(request, registry: registry, assignments: { granted },
                context: ToolCallContext(agentID: agent.id, workspace: repository.directory(for: agent)), host: host)
            let object = try JSONSerialization.jsonObject(with: result) as? [String: Any] ?? [:]
            let response = try JSONDecoder().decode(AppletResponse.self, from: JSONSerialization.data(withJSONObject: object["structuredContent"] ?? [:]))
            if object["isError"] as? Bool == true { throw AppletError(response.error ?? "The applet tool failed.") }
            return response
        }
        let package = source.lastPathComponent
        let registered = try await cli(["validate", "--path", package], agent: author)
        guard let id = registered.noodletID, let url = registered.url, registered.sessionID == nil else {
            throw AppletError("Validation failed to register without running.")
        }
        let info = try await cli(["info", "--path", package], agent: author)
        guard info.noodletID == id else { throw AppletError("Info lost the source identity.") }
        do {
            _ = try await cli(["info", "--id", url.absoluteString], agent: participant)
            throw AppletError("Unauthorized ID resolved.")
        } catch let error as AppletError where error.message.contains("unavailable to this caller") {}
        do {
            _ = try await cli(["info"] + ["--link", url.absoluteString, "--conversation", group.id.uuidString], agent: participant)
            throw AppletError("An unsent link resolved.")
        } catch where error.localizedDescription.contains("has not been shared") {}
        let send = MessengerCLI.run(arguments: ["messenger", "--agent-directory", repository.directory(for: author).path,
            "--send", "--conversation", group.id.uuidString, "--attach", url.absoluteString], environment: [:])
        guard send.exitCode == 0 else { throw AppletError(send.standardError) }
        let shared = ["--link", url.absoluteString, "--conversation", group.id.uuidString]
        let resolved = try await cli(["info"] + shared, agent: participant)
        guard resolved.noodletID == id, resolved.previewBookmark == nil else { throw AppletError("Shared access failed.") }
        let access = try await controller.resolvePreview(url)
        defer { try? manager.removeItem(at: access.url) }
        guard access.url.path == registered.path,
              try String(contentsOf: access.url.appendingPathComponent("index.html"), encoding: .utf8).contains("Try the preview") else {
            throw AppletError("Signed cross-sandbox package access failed.")
        }
        print("PASS: applet tool registration, stable info, ownership, Messenger webloc, shared participant access, signed preview bookmark")
        let opened = try await cli(["open", "--mode", "headless"] + shared, agent: participant)
        guard opened.sessionID != nil else { throw AppletError("Shared run failed.") }
        let capture = repository.directory(for: participant).appendingPathComponent("capture.png")
        _ = try await cli(["screenshot", "--output", "capture.png"] + shared, agent: participant)
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
        if LaunchChecks.current.contains(DevelopmentHook.holdPreview) { try await Task.sleep(for: .seconds(30)) }
        _ = try await cli(["close"] + shared, agent: participant)
        _ = try await controller.openNoodlet(url)
        let stored = try await cli(["eval", "--text", "return await noodle.storage.get('link-test');"] + shared, agent: participant)
        guard stored.value?.contains("saved") == true else { throw AppletError("Saved noodlet data did not survive reopening.") }
        _ = try await cli(["close"] + shared, agent: participant)
        print("PASS: live noodlet retains saved data after closing and reopening")
        print("APPLET LINK INTEGRATION PASSED")
    }
    /// A noodlet run by Noodle itself, as a phone or another Mac runs a Hub's: its files and its
    /// data come from Applet, as the Hub asks for them, and stay the same as Applet's own copy.
    static func runOnThisMac() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("NoodletDevice-Test-\(UUID())")
        defer { try? manager.removeItem(at: root) }
        let source = root.appendingPathComponent("Device.\(AppletBuildIdentity.current.fileExtension)")
        try manager.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"version":1,"title":"Noodlet on this Mac","runtime":"html","entry":"index.html","network":false}"#.utf8)
            .write(to: source.appendingPathComponent("noodlet.json"))
        try Data("<html><button id=\"play\">Try the preview</button></html>".utf8).write(to: source.appendingPathComponent("index.html"))
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("Noodle"))
        try repository.prepare()
        let controller = AppletController()
        // Applet uses a noodlet no bot made only once a person opens it there.
        guard let applet = AppletApplication.locate() else { throw AppletError("Noodle Applet is not installed.") }
        let opening = NSWorkspace.OpenConfiguration()
        opening.activates = false
        _ = try await NSWorkspace.shared.open([source], withApplicationAt: applet, configuration: opening)
        let canonical = source.resolvingSymlinksInPath().standardizedFileURL.path
        var listed: AppletItem?
        for _ in 0..<150 where listed?.sessionID == nil {
            listed = try? await controller.companion(AppletRequest(.list)).items?
                .first { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL.path == canonical }
            if listed?.sessionID == nil { try await Task.sleep(for: .milliseconds(200)) }
        }
        guard let id = listed?.noodletID, let session = listed?.sessionID else { throw AppletError("Applet did not list the noodlet opened in it.") }
        _ = try? await controller.companion(AppletRequest(.terminate, sessionID: session))
        func stored(_ call: NoodletStoreCall) async throws -> NoodletValue {
            var request = AppletRequest(.store)
            request.noodletID = id
            request.store = call
            return try await controller.companion(request).stored ?? .null
        }
        _ = try await stored(NoodletStoreCall(operation: "write", path: "storage/link-test.json",
                                             data: Data(#""saved""#.utf8).base64EncodedString()))

        var archive = AppletRequest(.archive)
        archive.noodletID = id
        let readied = try await controller.companion(archive)
        guard let artifact = readied.artifactID, let revision = readied.revision, let byteCount = readied.byteCount,
              readied.manifest?.title == "Noodlet on this Mac" else { throw AppletError("Applet did not ready the noodlet's files.") }
        let cache = manager.temporaryDirectory.appendingPathComponent("NoodletCache-Test-\(UUID())")
        defer { try? manager.removeItem(at: cache) }
        let files = try await NoodletCache(root: cache).package(id, revision: revision, byteCount: byteCount) { offset in
            var piece = AppletRequest(.artifact)
            piece.artifactID = artifact
            piece.offset = offset
            return try await controller.companion(piece).data ?? Data()
        }
        let store = RemoteNoodletStore { _, _, _, piece in
            var call = AppletRequest(.store)
            call.noodletID = id
            call.store = try JSONDecoder().decode(NoodletStoreCall.self, from: piece)
            return try JSONEncoder().encode(try await controller.companion(call).stored ?? .null)
        }
        let manifest = try JSONDecoder().decode(NoodletManifest.self, from: Data(contentsOf: files.appendingPathComponent("noodlet.json")))
        let page = NoodletPage(root: files, manifest: manifest, store: store, dataStore: .nonPersistent(),
                               features: NoodletDeviceHost.features, log: { print("noodlet \($0): \($1)") })
        let host = NoodletDeviceHost(page)
        defer { page.stop(); withExtendedLifetime(host) {} }
        try await page.load()
        let local = try await page.evaluate("return {button:document.querySelector('#play').textContent,features:noodle.features,saved:await noodle.storage.get('link-test')};")
        guard local.contains("Try the preview"), local.contains("files"), local.contains("saved") else {
            throw AppletError("The noodlet run by Noodle did not load or did not see Applet's data: \(local)")
        }
        _ = try await page.evaluate("await noodle.storage.set('device-test', 'from Noodle'); await noodle.secrets.set('device-secret', 'kept');")
        let secret = try await page.evaluate("return await noodle.secrets.get('device-secret');")
        guard secret.contains("kept") else { throw AppletError("A secret set from Noodle did not come back: \(secret)") }
        _ = try await page.evaluate("await noodle.secrets.delete('device-secret');")
        guard try await stored(NoodletStoreCall(operation: "read", path: "storage/device-test.json")) == .text(Data(#""from Noodle""#.utf8).base64EncodedString()) else {
            throw AppletError("Applet did not keep what Noodle saved.")
        }
        print("PASS: noodlet runs in Noodle from Applet's files, and shares its storage and secrets with Applet's copy")
    }
}
#endif
