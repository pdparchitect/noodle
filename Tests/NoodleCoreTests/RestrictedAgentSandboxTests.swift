import XCTest
@testable import NoodleCore

final class RestrictedAgentSandboxTests: XCTestCase {
    func testInstalledCodexCanInitializeWithAnIsolatedAccountDirectory() throws {
        let candidates = [URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
                          URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex")]
        guard let installed = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw XCTSkip("Codex is not installed")
        }
        let executable = installed.resolvingSymlinksInPath()
        let installation = executable.deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("Noodle"))
        let bot = try repository.createAgent(named: "Startup probe")
        let workspace = repository.directory(for: bot.agent)
        let account = root.appendingPathComponent("EmptyAccount"), temp = workspace.appendingPathComponent(".noodle/tmp")
        for directory in [account, temp] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let policy = RestrictedAgentSandbox.profile(workspace: workspace, repository: repository.rootURL,
            codexHome: account, executableDirectory: installation,
            application: installation, temporary: temp)
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", policy, executable.path, "app-server"]
        process.currentDirectoryURL = workspace
        process.environment = ["HOME": workspace.path, "CODEX_HOME": account.path, "TMPDIR": temp.path,
                               "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
        let request: [String: Any] = ["id": 1, "method": "initialize", "params": [
            "clientInfo": ["name": "noodle_storage_probe", "version": "test"],
            "capabilities": ["experimentalApi": true]]]
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request) + Data([10]))
        // A handshake only: no sign-in, model request, or real account directory.
        let received = expectation(description: "Codex initialized")
        let reader = JSONLineReader { object in
            if object["id"] as? Int == 1, object["result"] != nil { received.fulfill() }
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { reader.receive(data) }
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        wait(for: [received], timeout: 15)
    }

    func testRealProcessCanWorkAndMessageButCannotChangeConfigurationOrRuntime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("Noodle"))
        let created = try repository.createAgent(named: "Boundary")
        let layout = repository.storage(for: created.agent.id)
        let state = layout.sessionState(provider: .codex, extendedAccess: false)
        let original = try Data(contentsOf: layout.configuration)
        try Data("state".utf8).write(to: state)
        let account = root.appendingPathComponent("Account"), temp = layout.workspace.appendingPathComponent(".noodle/tmp")
        for directory in [account, temp] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = project.appendingPathComponent(".build/debug/NoodleMessenger")
        let policy = RestrictedAgentSandbox.profile(workspace: layout.workspace, repository: repository.rootURL,
            codexHome: account, executableDirectory: helper.deletingLastPathComponent(), application: project,
            temporary: temp)
        let script = """
        set -eu
        printf memory > "$1/allowed.txt"
        printf session > "$5/session.txt"
        printf temporary > "$TMPDIR/allowed.txt"
        if printf changed > "$2"; then exit 11; fi
        if printf changed > "$3"; then exit 12; fi
        if rm "$2"; then exit 13; fi
        if mv "$2" "$1/stolen.json"; then exit 14; fi
        ln -s "$2" "$1/config-link"
        if printf changed > "$1/config-link"; then exit 15; fi
        if ln "$2" "$1/config-hardlink"; then
          if printf changed > "$1/config-hardlink"; then exit 18; fi
        fi
        printf replacement > "$1/replacement"
        if mv "$1/replacement" "$2"; then exit 16; fi
        if mkdir "$4/unexpected"; then exit 17; fi
        "$6" --agent-directory "$1" --send --conversation "$7" --body 'sandbox reply'
        "$6" --agent-directory "$1" --get-latest
        """
        let process = Process(), errors = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", policy, "/bin/sh", "-c", script, "probe", layout.workspace.path,
                             layout.configuration.path, state.path, layout.package.path, account.path, helper.path,
                             created.conversation.id.uuidString]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": layout.workspace.path, "TMPDIR": temp.path]
        process.standardOutput = output; process.standardError = errors
        try process.run(); process.waitUntilExit()
        let details = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, details)
        XCTAssertEqual(try Data(contentsOf: layout.configuration), original)
        XCTAssertEqual(try String(contentsOf: state), "state")
        XCTAssertEqual(try String(contentsOf: layout.workspace.appendingPathComponent("allowed.txt")), "memory")
        XCTAssertTrue(try repository.loadMessages(conversationID: created.conversation.id).contains { $0.body == "sandbox reply" })
    }

    func testProfileQuotesPathsWithoutOpeningTheParent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sandbox-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("quote\" (allow default) \\ folder")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let policy = RestrictedAgentSandbox.profile(workspace: workspace, repository: root,
            codexHome: workspace, executableDirectory: URL(fileURLWithPath: "/bin"), application: workspace, temporary: workspace)
        let process = Process(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", policy, "/bin/sh", "-c", "set -e; printf ok > \"$1/ok\"; if touch \"$2/denied\"; then exit 10; fi", "probe", workspace.path, root.path]
        process.standardError = errors
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("ok")), "ok")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("denied").path))
    }
}
