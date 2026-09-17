import XCTest
import Darwin
@testable import NoodleCore

/// Runs the production CLIs under the strictest harness profile. Only the
/// app-side response is synthetic; no remote tool, computer, or applet is run.
final class BridgeCLISandboxTests: XCTestCase {
    func testMessengerCanUseWorkspaceBrokerWithoutNetworkOrSignalPermission() throws {
        try check(helper: "messenger", bridge: "messenger", arguments: ["--list-conversations"],
                  response: JSONEncoder().encode(MessengerCommandResult(exitCode: 0, standardOutput: "[]")), expected: "[]")
    }
    func testMCPCanUseWorkspaceBrokerWithoutNetworkOrSignalPermission() throws {
        try check(helper: "mcpshim", bridge: "mcp", arguments: ["tools", "--connection", UUID().uuidString],
                  response: JSONEncoder().encode(MCPBridgeResponse(result: Data("{\"tools\":[]}".utf8))), expected: "{\"tools\":[]}")
    }
    func testMCPExpandsFileInputsAndSavesBinaryResultsInsideSandbox() throws {
        let bytes = Data([0, 255, 128, 10])
        let result: [String: Any] = ["content": [
            ["type": "text", "text": "ready"],
            ["type": "image", "data": bytes.base64EncodedString(), "mimeType": "image/png"]],
            "structuredContent": ["accepted": true], "isError": true]
        try check(helper: "mcpshim", bridge: "mcp",
            arguments: ["call", "--connection", UUID().uuidString, "--tool", "fixture"],
            response: JSONEncoder().encode(MCPBridgeResponse(result: JSONSerialization.data(withJSONObject: result))),
            exitCode: 1,
            input: Data("{\"data\":\"@report.pdf\",\"literal\":\"@@name\"}".utf8),
            prepare: { workspace in try bytes.write(to: workspace.appendingPathComponent("report.pdf")) },
            inspectRequest: { data in
                let request = try JSONDecoder().decode(MCPBridgeRequest.self, from: data)
                let arguments = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.arguments)) as? [String: String])
                XCTAssertEqual(arguments, ["data": bytes.base64EncodedString(), "literal": "@name"])
            }, verify: { object, workspace in
                let result = try XCTUnwrap(object as? [String: Any])
                XCTAssertEqual((result["structuredContent"] as? [String: Bool])?["accepted"], true)
                let content = try XCTUnwrap(result["content"] as? [[String: Any]])
                XCTAssertEqual(content[0]["text"] as? String, "ready")
                XCTAssertEqual(content[1]["type"] as? String, "file")
                let path = try XCTUnwrap(content[1]["path"] as? String)
                XCTAssertTrue(path.hasPrefix(workspace.path + "/.noodle/mcp-attachments/"))
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
            })
    }
    func testMCPRawOutputAndToolErrorExitStatusInsideSandbox() throws {
        let result = "{\"content\":[{\"type\":\"image\",\"data\":\"AP8=\",\"mimeType\":\"image/png\"}],\"isError\":true}"
        try check(helper: "mcpshim", bridge: "mcp",
            arguments: ["call", "--raw", "--connection", UUID().uuidString, "--tool", "fixture", "--input", "{}"],
            response: JSONEncoder().encode(MCPBridgeResponse(result: Data(result.utf8))), expected: result, exitCode: 1,
            verify: { _, workspace in
                XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(MCPFileContent.directory).path))
            })
    }
    func testMCPResourceReadSavesBlobInsideSandbox() throws {
        let result = Data("{\"contents\":[{\"uri\":\"reports://file\",\"blob\":\"AP8=\",\"mimeType\":\"application/pdf\"}]}".utf8)
        try check(helper: "mcpshim", bridge: "mcp",
            arguments: ["read-resource", "--connection", UUID().uuidString, "--uri", "reports://file"],
            response: JSONEncoder().encode(MCPBridgeResponse(result: result)),
            inspectRequest: { data in
                let request = try JSONDecoder().decode(MCPBridgeRequest.self, from: data)
                XCTAssertEqual(request.action, .readResource)
                XCTAssertEqual(request.uri, "reports://file")
            }, verify: { object, _ in
                let result = try XCTUnwrap(object as? [String: Any])
                let content = try XCTUnwrap(result["contents"] as? [[String: Any]])
                let path = try XCTUnwrap(content.first?["path"] as? String)
                XCTAssertTrue(path.hasSuffix(".pdf"))
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data([0, 255]))
            })
    }
    func testMCPMissingFileFailsBeforeSendingRequest() throws {
        try check(helper: "mcpshim", bridge: "mcp",
            arguments: ["call", "--connection", UUID().uuidString, "--tool", "fixture", "--input", "{\"data\":\"@missing.pdf\"}"],
            response: Data(), exitCode: 1, expectsRequest: false, expectedError: "Cannot read MCP file reference")
    }
    func testMCPScriptChainsCallsThroughSkillLocalConnection() throws {
        let source = "const first = mcp.call('echo', {value: 1}); print(mcp.call('echo', {value: first.structuredContent.value + 1}).structuredContent);"
        var ids: Set<UUID> = []
        try check(helper: "mcpshim", bridge: "mcp", arguments: ["eval", source, "--timeout", "10"],
            response: Data(), expected: "{\"value\":2}", requestCount: 2, skillLocal: true,
            responseForRequest: { data, index in
                let request = try JSONDecoder().decode(MCPBridgeRequest.self, from: data)
                XCTAssertTrue(ids.insert(request.id).inserted)
                XCTAssertEqual(request.skillName, "mcp-script-fixture")
                XCTAssertNil(request.connectionID)
                XCTAssertEqual(request.action, .call)
                XCTAssertEqual(request.tool, "echo")
                XCTAssertLessThanOrEqual(request.expiresAt.timeIntervalSinceNow, 10)
                let value = try JSONDecoder().decode([String: Int].self, from: XCTUnwrap(request.arguments))
                XCTAssertEqual(value["value"], index + 1)
                return try JSONEncoder().encode(MCPBridgeResponse(result:
                    JSONSerialization.data(withJSONObject: ["structuredContent": value])))
            })
    }
    func testMCPScriptFileUsesExistingFileInputsAttachmentsAndRawResources() throws {
        let source = """
        const result = mcp.call('fixture', {data: '@report.pdf', literal: '@@name'});
        const raw = mcp.readResource('reports://file', {raw: true});
        print({result, raw});
        """
        let bytes = Data([0, 255])
        try check(helper: "mcpshim", bridge: "mcp",
            arguments: ["run", "workflow.js", "--connection", UUID().uuidString], response: Data(), requestCount: 2,
            responseForRequest: { data, index in
                let request = try JSONDecoder().decode(MCPBridgeRequest.self, from: data)
                let result: String
                if index == 0 {
                    XCTAssertEqual(request.action, .call)
                    XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: XCTUnwrap(request.arguments)),
                                   ["data": bytes.base64EncodedString(), "literal": "@name"])
                    result = #"{"content":[{"type":"image","data":"AP8=","mimeType":"image/png"}]}"#
                } else {
                    XCTAssertEqual(request.action, .readResource)
                    XCTAssertEqual(request.uri, "reports://file")
                    result = #"{"contents":[{"uri":"reports://file","blob":"AP8=","mimeType":"application/pdf"}]}"#
                }
                return try JSONEncoder().encode(MCPBridgeResponse(result: Data(result.utf8)))
            }, prepare: { workspace in
                try source.write(to: workspace.appendingPathComponent("workflow.js"), atomically: true, encoding: .utf8)
                try bytes.write(to: workspace.appendingPathComponent("report.pdf"))
            }, verify: { object, workspace in
                let values = try XCTUnwrap(object as? [String: Any])
                let result = try XCTUnwrap(values["result"] as? [String: Any])
                let content = try XCTUnwrap(result["content"] as? [[String: Any]])
                let path = try XCTUnwrap(content.first?["path"] as? String)
                XCTAssertTrue(path.hasPrefix(workspace.path + "/.noodle/mcp-attachments/"))
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
                let raw = try XCTUnwrap(values["raw"] as? [String: Any])
                XCTAssertEqual((raw["contents"] as? [[String: String]])?.first?["blob"], "AP8=")
                let directories = try FileManager.default.contentsOfDirectory(atPath: workspace.appendingPathComponent(MCPFileContent.directory).path)
                XCTAssertEqual(directories.count, 1)
            })
    }
    func testMCPScriptReadsSourceFromStdin() throws {
        try check(helper: "mcpshim", bridge: "mcp", arguments: ["run", "-", "--connection", UUID().uuidString],
            response: JSONEncoder().encode(MCPBridgeResponse(result: Data("{\"tools\":[{\"name\":\"echo\"}]}".utf8))),
            expected: "[\"echo\"]", input: Data("print(mcp.tools().tools.map(t => t.name))".utf8))
    }
    func testMCPScriptStopsOnRevokedConnectionWithoutReplaying() throws {
        try check(helper: "mcpshim", bridge: "mcp",
            arguments: ["eval", "mcp.tools(); mcp.tools(); print('unreachable')", "--connection", UUID().uuidString],
            response: Data(), exitCode: 1, expectedError: "no longer assigned", requestCount: 2,
            responseForRequest: { _, index in
                try JSONEncoder().encode(index == 0 ? MCPBridgeResponse(result: Data("{\"tools\":[]}".utf8))
                    : MCPBridgeResponse(error: "Connection is no longer assigned"))
            })
    }
    func testMCPScriptToolErrorExitsNonzero() throws {
        try check(helper: "mcpshim", bridge: "mcp",
            arguments: ["eval", "mcp.call('fixture'); print('unreachable')", "--connection", UUID().uuidString],
            response: JSONEncoder().encode(MCPBridgeResponse(result: Data("{\"isError\":true,\"content\":[]}".utf8))),
            exitCode: 1, expectedError: "MCP tool returned an error")
    }
    func testMCPScriptDeadlineStopsInfiniteLoopInsideSandbox() throws {
        let start = ProcessInfo.processInfo.systemUptime
        try check(helper: "mcpshim", bridge: "mcp",
            arguments: ["eval", "while (true) {}", "--connection", UUID().uuidString, "--timeout", "1"],
            response: Data(), exitCode: 1, expectsRequest: false, expectedError: "script timed out")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 10)
    }
    func testMCPScriptErrorsPrintReadableStackAndSyntaxLocation() throws {
        for (source, expected) in [
            ("function inner() { throw new Error('broken'); }\nfunction outer() { inner(); }\nouter();", "Error: broken\ninner@"),
            ("\nconst =", "workflow.js:2")
        ] {
            try check(helper: "mcpshim", bridge: "mcp", arguments: ["run", "workflow.js", "--connection", UUID().uuidString],
                response: Data(), exitCode: 1, expectsRequest: false, expectedError: expected,
                prepare: { workspace in
                    try source.write(to: workspace.appendingPathComponent("workflow.js"), atomically: true, encoding: .utf8)
                })
        }
    }
    func testMCPScriptDeadlineStopsBlockedOutputPipesInsideSandbox() throws {
        // The fixture deliberately drains pipes only after exit, like a caller
        // which has stopped consuming output. The watchdog must not share a
        // blocking FileHandle lock with print or console.log.
        for function in ["print", "console.log", "throw new Error"] {
            let start = ProcessInfo.processInfo.systemUptime
            try check(helper: "mcpshim", bridge: "mcp",
                arguments: ["eval", "\(function)('x'.repeat(1048576))", "--connection", UUID().uuidString, "--timeout", "1"],
                response: Data(), exitCode: 1, expectsRequest: false,
                expectedError: function == "print" ? "script timed out" : "xxxxxxxx")
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 10)
        }
    }
    func testMCPScriptRejectsLinkedFilesAndInvalidOptionsBeforeDispatch() throws {
        for path in ["linked.js", "hardlinked.js", "../outside.js"] {
            try check(helper: "mcpshim", bridge: "mcp", arguments: ["run", path, "--connection", UUID().uuidString],
                response: Data(), exitCode: 1, expectsRequest: false, expectedError: path == "../outside.js" ? "without '..'" : "Cannot read script",
                prepare: { workspace in
                    let file = workspace.appendingPathComponent("script.js")
                    try "mcp.tools()".write(to: file, atomically: true, encoding: .utf8)
                    try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("linked.js"), withDestinationURL: file)
                    try FileManager.default.linkItem(at: file, to: workspace.appendingPathComponent("hardlinked.js"))
                })
        }
        try check(helper: "mcpshim", bridge: "mcp", arguments: ["eval", "mcp.tools()", "--timeout", "0"],
            response: Data(), exitCode: 1, expectsRequest: false, expectedError: "--timeout must be")
        try check(helper: "mcpshim", bridge: "mcp", arguments: ["eval", "mcp.tools()", "--raw"],
            response: Data(), exitCode: 1, expectsRequest: false, expectedError: "Unknown or repeated script option")
    }
    func testComputerCanUseWorkspaceBrokerWithoutNetworkOrSignalPermission() throws {
        try check(helper: "computer", bridge: "computer", arguments: ["list"], response: Data("{\"computers\":[]}".utf8), expected: "{\"computers\":[]}")
    }
    func testAppletCanUseWorkspaceBrokerWithoutNetworkOrSignalPermission() throws {
        try check(helper: "noodlet", bridge: "applet", arguments: ["list"], response: Data("{\"version\":1,\"items\":[]}".utf8), expected: "{\"version\":1,\"items\":[]}")
    }
    private func check(helper: String, bridge: String, arguments: [String], response: Data, expected: String? = nil,
                       exitCode: Int32 = 0, input: Data? = nil, expectsRequest: Bool = true, expectedError: String? = nil,
                       requestCount: Int = 1, skillLocal: Bool = false,
                       responseForRequest: ((Data, Int) throws -> Data)? = nil,
                       prepare: (URL) throws -> Void = { _ in },
                       inspectRequest: @escaping (Data) throws -> Void = { _ in },
                       verify: (Any, URL) throws -> Void = { _, _ in }) throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let environment = ProcessInfo.processInfo.environment
        let configured = environment["NOODLE_TEST_CLI_APPLICATION"]
        let application = configured.map { URL(fileURLWithPath: $0) } ?? project.appendingPathComponent(".build/Noodle Dev.app")
        let executable = application.appendingPathComponent("Contents/Helpers/" + helper)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            let reason = "Missing sandbox CLI fixture: \(executable.path). Run zsh Tests/build-sandbox-cli-fixture.sh and set NOODLE_TEST_CLI_APPLICATION to its output."
            if configured != nil || environment["CI"] == "true" { throw HarnessSetupError(reason) }
            throw XCTSkip(reason)
        }
        let signature = Process()
        signature.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signature.arguments = ["--verify", "--strict", executable.path]
        try signature.run(); signature.waitUntilExit()
        XCTAssertEqual(signature.terminationStatus, 0, "The fixture must have a valid code signature")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        let bot = try repository.createAgent(named: "CLI boundary fixture")
        let workspace = repository.directory(for: bot.agent)
        var invocation = executable
        if skillLocal {
            let skill = try WorkspaceMailbox(workspace: workspace, path: ".agents/skills/mcp-script-fixture", create: true)
            try skill.symlink("mcpshim", destination: executable.path)
            invocation = skill.url.appendingPathComponent("mcpshim")
        }
        try prepare(workspace)
        let mailbox = try WorkspaceMailbox(workspace: workspace, path: ".noodle/" + bridge + "-bridge", create: true)
        let token = UUID().uuidString
        try mailbox.write(MCPBridgeSession(token: token, processID: getpid()), named: "session.json")
        let received = expectsRequest ? expectation(description: "Authenticated request reached the workspace mailbox") : nil
        received?.expectedFulfillmentCount = requestCount
        let queue = DispatchQueue(label: "Noodle.fixture-mailbox")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        var answered: Set<String> = []
        timer.setEventHandler {
            guard let files = try? mailbox.names(), let request = files.first(where: { $0.hasSuffix(".request") && !answered.contains($0) }),
                  let data = try? mailbox.read(request, limit: 1_048_576),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let index = answered.count
            answered.insert(request)
            XCTAssertTrue(expectsRequest, "Invalid input must fail before dispatch")
            XCTAssertEqual(object[bridge == "mcp" || bridge == "messenger" ? "session" : "token"] as? String, token)
            do { try inspectRequest(data) } catch { XCTFail("Invalid request: \(error)") }
            do {
                let reply = try responseForRequest?(data, index) ?? response
                try mailbox.writeData(reply, named: String(request.dropLast(8)) + ".response")
            } catch { XCTFail("Could not respond: \(error)") }
            received?.fulfill()
        }
        timer.schedule(deadline: .now(), repeating: .milliseconds(25)); timer.resume()
        defer { timer.cancel() }
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        let context = bridge == "messenger" ? ["--agent-directory", workspace.path] : []
        process.arguments = ["-p", AppleAgentSandbox.profile(application: application, workspace: workspace), invocation.path] + context + arguments
        process.currentDirectoryURL = workspace
        let temporary = try WorkspaceMailbox(workspace: workspace, path: ".noodle/tmp", create: true).url
        process.environment = ["HOME": workspace.path, "PATH": "/usr/bin:/bin", "TMPDIR": temporary.path,
            "TMPPREFIX": temporary.appendingPathComponent("zsh").path]
        process.standardOutput = output; process.standardError = errors
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        if let input { try stdin.fileHandleForWriting.write(contentsOf: input) }
        try stdin.fileHandleForWriting.close()
        if let received { wait(for: [received], timeout: 15) }
        let exited = expectation(description: "CLI completed")
        DispatchQueue.global().async { process.waitUntilExit(); exited.fulfill() }
        wait(for: [exited], timeout: 15)
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        let errorOutput = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, exitCode, errorOutput)
        if let expectedError {
            XCTAssertTrue(errorOutput.contains(expectedError), errorOutput)
            XCTAssertTrue(try mailbox.names().allSatisfy { !$0.hasSuffix(".request") })
            return
        }
        let actual = try JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile())
        if let expected {
            let wanted = try JSONSerialization.jsonObject(with: Data(expected.utf8))
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys]),
                           try JSONSerialization.data(withJSONObject: wanted, options: [.sortedKeys]))
        }
        try verify(actual, workspace)
    }
}
