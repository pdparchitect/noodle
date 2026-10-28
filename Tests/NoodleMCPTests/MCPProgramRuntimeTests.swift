import XCTest
import NoodleCore
import NoodleMCP

final class MCPProgramRuntimeTests: XCTestCase {
    func testFirstUseListsToolsAndKeepsTheSecretOutOfTheReply() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".py")
        try fakeServer.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        let secrets = MCPProgramMemorySecrets()
        let runtime = MCPProgramRuntime(secrets: secrets)
        var program = try MCPProgramRecord(name: "Anytype", executable: "/usr/bin/python3", arguments: [script.path],
                                           environmentNames: ["OPENAPI_MCP_HEADERS"])
        let executable = try MCPProgramRecord.resolveExecutable(program.executable, lookup: MCPProgramRecord.pathLookup)
        let directory = MCPProgramRecord.workingDirectory(root: root, id: program.id)
        program.consentedSubject = MCPProgramRecord.subject(executable: executable, arguments: program.arguments,
                                                             workingDirectory: directory, environmentNames: program.environmentNames)
        try await runtime.saveSecrets(["OPENAPI_MCP_HEADERS": "secret-value"], id: program.id)
        defer { Task { try? await runtime.remove(program.id) } }
        let listed = try await runtime.perform(MCPBridgeRequest(session: "s", action: .tools, tool: nil, arguments: nil),
                                                program: program, root: root, user: NSUserName(), authorized: { true })
        let text = String(decoding: listed, as: UTF8.self)
        XCTAssertTrue(text.contains("ping"))
        XCTAssertFalse(text.contains("secret-value"))
        XCTAssertFalse(text.contains("err "))
        let captured = await runtime.capturedError(program.id)
        XCTAssertFalse(captured.contains("secret-value"))
        XCTAssertTrue(captured.contains("[redacted]"))
        let env = try String(contentsOf: directory.appendingPathComponent("env.txt"), encoding: .utf8)
        XCTAssertTrue(env.contains("HOME=unset"))
        XCTAssertTrue(env.contains("USER=\(NSUserName())"))
        let called = try await runtime.perform(MCPBridgeRequest(session: "s", action: .call, tool: "ping", arguments: Data("{}".utf8)),
                                                program: program, root: root, user: NSUserName(), authorized: { true })
        XCTAssertTrue(String(decoding: called, as: UTF8.self).contains("pong"))
        XCTAssertFalse(String(decoding: called, as: UTF8.self).contains("secret-value"))
        program.consentedSubject = nil
        do {
            _ = try await runtime.perform(MCPBridgeRequest(session: "s", action: .tools, tool: nil, arguments: nil),
                                           program: program, root: root, user: NSUserName(), authorized: { true })
            XCTFail("A declined program stays unconnected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Approve this program"))
        }
    }

    private let fakeServer = """
    import json, os, sys
    secret = os.environ.get("OPENAPI_MCP_HEADERS", "")
    sys.stderr.write("err " + secret + "\\n")
    sys.stderr.flush()
    home = "unset" if "HOME" not in os.environ else "set"
    with open("env.txt", "w", encoding="utf-8") as handle:
        handle.write("HOME=" + home + "\\nUSER=" + os.environ.get("USER", "") + "\\n")
    while True:
        line = sys.stdin.readline()
        if not line:
            break
        message = json.loads(line)
        method = message.get("method")
        if method == "notifications/initialized":
            continue
        if method == "initialize":
            version = message.get("params", {}).get("protocolVersion", "2024-11-05")
            result = {"protocolVersion": version, "capabilities": {"tools": {}}, "serverInfo": {"name": "fake", "version": "0"}}
        elif method == "tools/list":
            result = {"tools": [{"name": "ping", "description": "p", "inputSchema": {"type": "object"}}]}
        elif method == "tools/call":
            result = {"content": [{"type": "text", "text": "pong"}], "isError": False}
        else:
            continue
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": message.get("id"), "result": result}) + "\\n")
        sys.stdout.flush()
    """
}
