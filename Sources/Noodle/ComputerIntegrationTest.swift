#if NOODLE_DEV_HOOKS
import AppKit
import ComputerBridge
import NoodleComputerTools
import NoodleCore
import NoodleLaunchChecks
import SwiftUI

/// Explicit opt-in fixture, before NoodleStore creation: never opens the real
/// repository, starts agents, or accesses the production provider endpoint.
@MainActor enum ComputerIntegrationTest {
    /// UI-only fixture: no real agents, assignments, provider or guest operations.
    static func checkPicker() async throws {
        if LaunchChecks.current.contains(DevelopmentHook.computerUpdateNotice) {
            try await checkUpdateNotice()
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoodlePicker-Test-\(UUID().uuidString)")
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        defer { try? FileManager.default.removeItem(at: root) }
        let computers = [
            RemoteComputer(id: UUID(), name: "Design Desktop", kind: "Desktop", state: "Running", symbol: "desktopcomputer", colour: 1),
            RemoteComputer(id: UUID(), name: "Build Shell", kind: "Shell", state: "Stopped", symbol: "terminal", colour: 3),
            RemoteComputer(id: UUID(), name: "Research", kind: "Desktop", state: "Stopped", symbol: "globe", colour: 2)
        ]
        var registry = ComputerAssignments()
        registry.computers = computers
        try registry.save(root: root)
        let controller = ComputerController(repository: repository, socket: root.appendingPathComponent("offline.sock"))
        let emptyRoot = root.appendingPathComponent("empty")
        let emptyRepository = WorkspaceRepository(rootURL: emptyRoot)
        try emptyRepository.prepare()
        let emptyController = ComputerController(repository: emptyRepository, socket: emptyRoot.appendingPathComponent("offline.sock"),
            applicationLookup: LaunchChecks.current.contains(DevelopmentHook.computerDownload) ? { nil } : {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: ComputerConnection.providerID)
            })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Computer Assignment Preview"
        window.contentView = NSHostingView(rootView: ComputerPickerFixture(controller: controller, emptyController: emptyController))
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        print("COMPUTER PICKER READY: isolated populated and empty catalogues")
        for _ in 0..<600 {
            guard window.isVisible else { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        window.close()
    }
    private static func checkUpdateNotice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoodleUpdateNotice-Test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let computer = RemoteComputer(id: UUID(), name: "Design Desktop", kind: "Desktop", state: "Running", symbol: "desktopcomputer", colour: 1)
        func controller(updated: Bool) async throws -> ComputerController {
            let repository = WorkspaceRepository(rootURL: root.appendingPathComponent(updated ? "updated" : "older"))
            try repository.prepare()
            let controller = ComputerController(repository: repository, applicationLookup: { nil }, connection: { _ in
                var response = ComputerResponse(computers: [computer])
                var capabilities = ComputerCapabilities()
                if !updated { capabilities.features.remove("file-transfer-v1") }
                response.capabilities = capabilities
                return response
            })
            await controller.refresh()
            return controller
        }
        let older = try await controller(updated: false), updated = try await controller(updated: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 520),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Computer Update Notice Preview"
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: ComputerPickerFixture(controller: older, emptyController: updated, updateComparison: true))
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw ComputerBridgeError("Could not capture the update notice preview.")
        }
        host.effectiveAppearance.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw ComputerBridgeError("Could not encode the update notice preview.")
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("NoodleComputerUpdateNotice-\(UUID().uuidString).png")
        try png.write(to: output)
        print("COMPUTER UPDATE NOTICE SNAPSHOT: \(output.path)")
    }
    static func checkDiscovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoodleDiscovery-Test-\(UUID().uuidString)")
        let repository = WorkspaceRepository(rootURL: root); try repository.prepare()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = ComputerController(repository: repository)
        let response = try await controller.call(.init(.list))
        print("DISCOVERY PASSED: installed provider available, \(response.computers?.count ?? 0) computers; none started or changed")
    }
    static func run() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoodleBridge-Test-\(UUID().uuidString)")
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
        let repository = WorkspaceRepository(rootURL: root, launcherExecutableURL: helpers.appendingPathComponent("messenger"))
        try repository.prepare()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try repository.createAgent(named: "Fixture A"), b = try repository.createAgent(named: "Fixture B")
        let socket = try ComputerConnection.socketURL().deletingLastPathComponent().appendingPathComponent("t.sock")
        defer { try? Data().write(to: socket.deletingLastPathComponent().appendingPathComponent("fixture-finished")) }
        let controller = ComputerController(repository: repository, socket: socket)
        await controller.refresh()
        guard controller.available, let computer = controller.registry.computers.first else {
            throw ComputerBridgeError(controller.failure ?? "No fixture provider.")
        }
        // The same pieces the app wires together, with the provider pointed at the fixture's
        // socket instead of running inside the extension against a user's companion.
        let assignments = ToolAssignmentStore(), registry = ToolProviderRegistry()
        let staging = socket.deletingLastPathComponent(), team = try ComputerConnection.signingTeam()
        try registry.register(ComputerToolProvider(stagingRoot: { staging }) { try await ComputerConnection.call($0, socket: socket, team: team) })
        let host = ToolHostServices.repository(repository, revoked: { kind, id, agent in
            guard kind == "computer", let revoked = UUID(uuidString: id) else { return }
            Task { @MainActor in controller.revoke(computer: revoked, agent: agent) }
        }) { assignments.assignments(for: $0) }
        let broker = ToolBridgeBroker(registry: registry, host: host) { assignments.assignments(for: $0) }
        controller.onAssignmentsChange = { assignments.replace("computer", with: $0); broker.synchronizeSkills() }
        try controller.assign([computer.id], to: a.agent); try controller.assign([computer.id], to: b.agent)
        controller.start(agents: [a.agent, b.agent])
        try broker.start(agents: [a.agent, b.agent].map { ToolBridgeAgent(id: $0.id, workspace: repository.directory(for: $0)) })
        defer { broker.stop() }
        func cli(_ args: [String], _ agent: AgentRecord = a.agent) async throws -> [String: Any] {
            print("CLI TEST: \(agent.displayName) \(args.first ?? "")")
            let cwd = repository.directory(for: agent)
            let executable = cwd.appendingPathComponent(".agents/skills/messenger/messenger")
            return try await Task.detached {
                let process = Process(), output = Pipe(), errors = Pipe()
                process.executableURL = executable; process.arguments = ["tool", "computer"] + args; process.currentDirectoryURL = cwd
                process.standardOutput = output; process.standardError = errors
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let failure = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                // A tool result carries its JSON in structuredContent; a tool error its message in content.
                let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard process.terminationStatus == 0, let structured = result?["structuredContent"] as? [String: Any] else {
                    throw ComputerBridgeError((((result?["content"] as? [[String: Any]])?.first)?["text"] as? String) ?? failure)
                }
                return structured
            }.value
        }
        func expectDenied(_ args: [String], _ agent: AgentRecord) async throws {
            do { _ = try await cli(args, agent) }
            catch { print("PASS: request denied: \(error.localizedDescription)"); return }
            throw ComputerBridgeError("An unauthorized request succeeded.")
        }
        let base = ["--computer", computer.id.uuidString]
        let list = try await cli(["list"])
        guard (list["computers"] as? [[String: Any]])?.count == 1 else { throw ComputerBridgeError("Discovery failed.") }
        _ = try await cli(["start"] + base)
        await controller.refresh()
        // Exercise the real CLI, broker, App Group and guest helper before any
        // terminal exists. Include NUL, non-UTF8 bytes and shell metacharacters.
        let workspace = repository.directory(for: a.agent)
        let guestPath = "/workspace/transfer ' $()\n.bin"
        let binary = Data((0..<1_250_017).map { UInt8(truncatingIfNeeded: $0) })
        try binary.write(to: workspace.appendingPathComponent("upload.bin"))
        let began = Date()
        let uploaded = try await cli(["upload"] + base + ["--source", "upload.bin", "--destination", guestPath])
        guard (uploaded["byteCount"] as? NSNumber)?.intValue == binary.count else { throw ComputerBridgeError("Upload byte count is incorrect.") }
        let downloaded = try await cli(["download"] + base + ["--source", guestPath, "--destination", "download.bin"])
        guard (downloaded["byteCount"] as? NSNumber)?.intValue == binary.count,
              try Data(contentsOf: workspace.appendingPathComponent("download.bin")) == binary else {
            throw ComputerBridgeError("CLI binary transfer was corrupted.")
        }
        try await expectDenied(["upload"] + base + ["--source", "upload.bin", "--destination", guestPath], a.agent)
        try await expectDenied(["download"] + base + ["--source", guestPath, "--destination", "download.bin"], a.agent)
        try await expectDenied(["download"] + base + ["--source", "/workspace/missing-transfer-file", "--destination", "missing.bin"], a.agent)
        try await expectDenied(["download"] + base + ["--source", "/workspace", "--destination", "folder.bin"], a.agent)
        try await expectDenied(["download"] + base + ["--source", guestPath, "--destination", "../escape.bin"], a.agent)
        try Data().write(to: workspace.appendingPathComponent("empty"))
        _ = try await cli(["upload"] + base + ["--source", "empty", "--destination", "/workspace/empty-transfer"])
        _ = try await cli(["download"] + base + ["--source", "/workspace/empty-transfer", "--destination", "empty-copy"])
        guard try Data(contentsOf: workspace.appendingPathComponent("empty-copy")).isEmpty else { throw ComputerBridgeError("Empty file transfer failed.") }
        print("PASS: native CLI binary/empty transfers, exact byte counts, literal filenames, no overwrite, missing/directory/escape errors (\(Date().timeIntervalSince(began))s)")
        let openedA = try await cli(["open"] + base), openedB = try await cli(["open"] + base, b.agent)
        guard let idA = openedA["terminalID"] as? String, let idB = openedB["terminalID"] as? String, idA != idB else {
            throw ComputerBridgeError("Agents did not receive separate terminals.")
        }
        let terminalA = base + ["--terminal", idA], terminalB = base + ["--terminal", idB]
        _ = try await cli(["resize"] + terminalA + ["--columns", "88", "--rows", "28"])
        _ = try await cli(["write"] + terminalA + ["--text", "printf 'shared-fixture' > /workspace/bridge-sentinel; printf '\\n__BRIDGE_%s__\\n' READY; stty size"])
        var ready = false
        for _ in 0..<30 {
            let text = try await cli(["read"] + terminalA)["text"] as? String ?? ""
            if text.contains("__BRIDGE_READY__"), text.contains("28 88") { ready = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard ready else { throw ComputerBridgeError("Guest input, output or resize failed.") }
        _ = try await cli(["write"] + terminalB + ["--text", "cat /workspace/bridge-sentinel"] , b.agent)
        try await Task.sleep(for: .milliseconds(250))
        guard (try await cli(["read"] + terminalB, b.agent)["text"] as? String)?.contains("shared-fixture") == true else {
            throw ComputerBridgeError("Assigned agents did not share guest files.")
        }
        try await expectDenied(["read"] + terminalA, b.agent)
        try await expectDenied(["present"] + terminalA + ["--conversation", b.conversation.id.uuidString], b.agent)
        try await expectDenied(["present", "--computer", UUID().uuidString, "--terminal", idA, "--conversation", a.conversation.id.uuidString], a.agent)
        _ = try await cli(["present"] + terminalA + ["--conversation", a.conversation.id.uuidString, "--message", "Here is the saved terminal preview."])
        let attachment = try repository.loadAttachments(conversationID: a.conversation.id).first!
        guard case .computer(_, let terminal, let view)? = attachment.companion, attachment.card != nil,
              terminal?.uuidString == idA, view == "terminal" else { throw ComputerBridgeError("No computer link attachment.") }
        if controller.registry.computers.first(where: { $0.id == computer.id })?.hasWebDisplay != true {
            let single = try await cli(["present"] + base + ["--conversation", a.conversation.id.uuidString])
            guard single["terminalID"] as? String == idA else { throw ComputerBridgeError("Sole terminal not inferred.") }
            let extra = try await cli(["open"] + base)["terminalID"] as! String
            try await expectDenied(["present"] + base + ["--conversation", a.conversation.id.uuidString], a.agent)
            _ = try await cli(["close"] + base + ["--terminal", extra])
        }
        try await expectDenied(["present"] + terminalB + ["--conversation", a.conversation.id.uuidString], b.agent)
        try controller.assign([], to: b.agent)
        try await expectDenied(["read"] + terminalB, b.agent)
        try await expectDenied(["download"] + base + ["--source", guestPath, "--destination", "revoked.bin"], b.agent)
        _ = try await cli(["read"] + terminalA)
        print("PASS: discovery, two assignments, separate PTYs, shared guest files, CLI input/read/resize, typed card, membership checks and revocation")

        if LaunchChecks.current.contains(DevelopmentHook.computerWeb) {
            _ = try await cli(["write"] + terminalA + ["--text", "apk add --no-cache busybox-extras && printf '__HTTP_%s__\\n' READY"])
            var httpReady = false
            for _ in 0..<60 {
                if (try await cli(["read"] + terminalA)["text"] as? String)?.contains("__HTTP_READY__") == true { httpReady = true; break }
                try await Task.sleep(for: .seconds(1))
            }
            guard httpReady else { throw ComputerBridgeError("Fixture HTTP server package did not install.") }
            _ = try await cli(["write"] + terminalA + ["--text", "mkdir -p /workspace/web; printf '%s' '<html><body style=\"background:#132d35;color:white;font:20px sans-serif;padding:40px\"><h1>Computer live display</h1><input placeholder=\"Type here\"><button onclick=\"document.body.dataset.done=1;this.textContent=String(1+1)\">Click to verify</button></body></html>' > /workspace/web/index.html; busybox httpd -p 8080 -h /workspace/web"])
            _ = try await cli(["write"] + terminalA + ["--text", "busybox-extras httpd -p 8080 -h /workspace/web"])
            try await Task.sleep(for: .seconds(1))
            await controller.refresh()
            _ = try await cli(["present"] + base + ["--conversation", a.conversation.id.uuidString])
            guard case .computer(_, let terminal, let view)? = try repository.loadAttachments(conversationID: a.conversation.id).last!.companion,
                  view == "web", terminal == nil else { throw ComputerBridgeError("Web link unexpectedly requires a terminal.") }
            _ = try await controller.call(.init(.display, computerID: computer.id, agentID: a.agent.id))
            print("PASS: web presentation reference resolves through the authorized broker")
        }
        _ = try await cli(["write"] + terminalA + ["--text", "exit"])
        try await Task.sleep(for: .milliseconds(300))
        guard try await cli(["read"] + terminalA)["exited"] as? Bool == true else { throw ComputerBridgeError("Exit status not reported.") }
        let reopened = try await cli(["open"] + base)
        guard let replacement = reopened["terminalID"] as? String, replacement != idA else { throw ComputerBridgeError("Could not open a replacement shell.") }
        _ = try await cli(["close"] + base + ["--terminal", replacement])
        print("COMPUTER INTEGRATION PASSED: exited shells can be replaced; closing a preview does not stop the computer")
    }
}

private struct ComputerPickerFixture: View {
    let controller: ComputerController
    let emptyController: ComputerController
    var updateComparison = false
    @State private var selected: Set<UUID> = []
    @State private var emptySelected: Set<UUID> = []
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 16) {
                if updateComparison { Text("Update required").font(.headline) }
                ComputerAssignmentPicker(controller: controller, selectedIDs: $selected)
            }
            VStack(alignment: .leading, spacing: 16) {
                if updateComparison { Text("After updating").font(.headline) }
                ComputerAssignmentPicker(controller: emptyController, selectedIDs: $emptySelected)
            }
        }
        .padding(24).frame(width: 960, height: updateComparison ? 520 : 420)
        .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark)
        .onAppear {
            if updateComparison {
                selected = Set(controller.registry.computers.map(\.id))
                emptySelected = Set(emptyController.registry.computers.map(\.id))
            }
        }
    }
}
#endif
