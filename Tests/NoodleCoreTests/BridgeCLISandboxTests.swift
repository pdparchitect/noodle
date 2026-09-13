import XCTest
import Darwin
@testable import NoodleCore

/// Runs the actual signed CLIs under the strictest harness profile. Only the
/// app-side response is synthetic; no remote tool, computer, or applet is run.
final class BridgeCLISandboxTests: XCTestCase {
    func testMCPCanUseWorkspaceBrokerWithoutNetworkOrSignalPermission() throws {
        try check(helper: "mcpshim", bridge: "mcp", arguments: ["tools", "--connection", UUID().uuidString],
                  response: JSONEncoder().encode(MCPBridgeResponse(result: Data("{\"tools\":[]}".utf8))))
    }
    func testComputerCanUseWorkspaceBrokerWithoutNetworkOrSignalPermission() throws {
        try check(helper: "computer", bridge: "computer", arguments: ["list"], response: Data("{\"computers\":[]}".utf8))
    }
    func testAppletCanUseWorkspaceBrokerWithoutNetworkOrSignalPermission() throws {
        try check(helper: "noodlet", bridge: "applet", arguments: ["list"], response: Data("{\"version\":1,\"items\":[]}".utf8))
    }
    private func check(helper: String, bridge: String, arguments: [String], response: Data) throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let application = project.appendingPathComponent(".build/Noodle Local.app")
        let executable = application.appendingPathComponent("Contents/Helpers/" + helper)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw XCTSkip("Build the signed development app to check bundled CLIs.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        let bot = try repository.createAgent(named: "CLI boundary fixture")
        let workspace = repository.directory(for: bot.agent)
        let mailbox = try WorkspaceMailbox(workspace: workspace, path: ".noodle/" + bridge + "-bridge", create: true)
        let token = UUID().uuidString
        try mailbox.write(MCPBridgeSession(token: token, processID: getpid()), named: "session.json")
        let received = expectation(description: "Authenticated request reached the workspace mailbox")
        let queue = DispatchQueue(label: "Noodle.fixture-mailbox")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        var answered = false
        timer.setEventHandler {
            guard !answered, let files = try? mailbox.names(), let request = files.first(where: { $0.hasSuffix(".request") }),
                  let data = try? mailbox.read(request, limit: 1_048_576),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            answered = true
            XCTAssertEqual(object[bridge == "mcp" ? "session" : "token"] as? String, token)
            try? mailbox.writeData(response, named: String(request.dropLast(8)) + ".response")
            received.fulfill()
        }
        timer.schedule(deadline: .now(), repeating: .milliseconds(25)); timer.resume()
        defer { timer.cancel() }
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", AppleAgentSandbox.profile(application: application, workspace: workspace), executable.path] + arguments
        process.currentDirectoryURL = workspace
        let temporary = try WorkspaceMailbox(workspace: workspace, path: ".noodle/tmp", create: true).url
        process.environment = ["HOME": workspace.path, "PATH": "/usr/bin:/bin", "TMPDIR": temporary.path,
            "TMPPREFIX": temporary.appendingPathComponent("zsh").path]
        process.standardOutput = output; process.standardError = errors
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        wait(for: [received], timeout: 5)
        let exited = expectation(description: "CLI completed")
        DispatchQueue.global().async { process.waitUntilExit(); exited.fulfill() }
        wait(for: [exited], timeout: 5)
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
    }
}
