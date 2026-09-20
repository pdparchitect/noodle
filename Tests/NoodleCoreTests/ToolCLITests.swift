import XCTest
@testable import NoodleCore

final class ToolCLITests: XCTestCase {
    private struct Shout: ToolProvider {
        let kind = ToolProviderKind.builtIn
        let manifest = ToolProviderManifest(id: "shout", title: "Shout", summary: "Upper-case text")
        func tools(context: ToolCallContext) async throws -> Data {
            Data(#"{"tools":[{"name":"say","description":"Shout it","inputSchema":{"type":"object","properties":{"text":{"type":"string"},"times":{"type":"integer"}}}}]}"#.utf8)
        }
        func call(_ tool: String, arguments: Data, files: [ToolFile], context: ToolCallContext) async throws -> Data {
            let object = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] ?? [:]
            let text = String(repeating: (object["text"] as? String ?? "").uppercased(), count: object["times"] as? Int ?? 1)
            return try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": text]], "isError": text.isEmpty])
        }
    }

    /// Stands in for a tool connection: remote-style tools with opaque string arguments and image results.
    private struct Picture: ToolProvider {
        let kind: ToolProviderKind
        let manifest: ToolProviderManifest
        func tools(context: ToolCallContext) async throws -> Data {
            Data(#"{"tools":[{"name":"describe","inputSchema":{"type":"object","properties":{"image":{"type":"string"},"note":{"type":"string"}}}}]}"#.utf8)
        }
        func call(_ tool: String, arguments: Data, files: [ToolFile], context: ToolCallContext) async throws -> Data {
            let object = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] ?? [:]
            return try JSONSerialization.data(withJSONObject: ["isError": false, "content": [
                ["type": "text", "text": "image=\(object["image"] as? String ?? "") note=\(object["note"] as? String ?? "")"],
                ["type": "image", "mimeType": "image/png", "data": Data("PNG".utf8).base64EncodedString()]]])
        }
    }

    private var root: URL!
    private var layout: AgentStorageLayout!
    private var broker: ToolBridgeBroker!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let agents = root.appendingPathComponent("Agents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        layout = AgentStorageLayout(package: agents.appendingPathComponent(UUID().uuidString))
        try layout.create()
        try Data("{}".utf8).write(to: layout.configuration)
        let registry = ToolProviderRegistry()
        try registry.register(Shout())
        try registry.register(Picture(kind: .connection, manifest: .init(id: "mcp-pictures", title: "Pictures", summary: "")))
        try registry.register(Picture(kind: .appExtension, manifest: .init(id: "camera", title: "Camera", summary: "")))
        broker = ToolBridgeBroker(registry: registry) { _ in .none }
        try broker.start(agents: [ToolBridgeAgent(id: UUID(), workspace: layout.workspace)])
    }
    override func tearDownWithError() throws { broker?.stop(); try? FileManager.default.removeItem(at: root) }

    private func messenger(_ arguments: String...) -> MessengerCommandResult {
        MessengerCLI.run(arguments: ["messenger", "--agent-directory", layout.workspace.path] + arguments, environment: [:])
    }
    private func json(_ result: MessengerCommandResult) throws -> NSDictionary {
        try JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8)) as! NSDictionary
    }

    func testParsingSeparatesProviderToolAndFlags() throws {
        XCTAssertEqual(try ToolCLI.parse([]), .providers)
        XCTAssertEqual(try ToolCLI.parse(["vision"]), .tools("vision"))
        XCTAssertEqual(try ToolCLI.parse(["vision", "ocr", "--help"]), .inspect("vision", "ocr"))
        XCTAssertEqual(try ToolCLI.parse(["vision", "ocr"]), .call("vision", "ocr", []))
        XCTAssertEqual(try ToolCLI.parse(["vision", "ocr", "--image", "--help"]), .call("vision", "ocr", ["--image", "--help"]))
        for bad in [["--help"], ["vision", "--image", "a"], ["vision", "ocr", "stray"], ["vision", ""]] {
            XCTAssertThrowsError(try ToolCLI.parse(bad), bad.joined(separator: " "))
        }
    }

    func testMessengerToolListsInspectsAndCallsThroughTheBridge() throws {
        let providers = messenger("tool")
        XCTAssertEqual(providers.exitCode, 0, providers.standardError)
        XCTAssertEqual((try json(providers)["providers"] as? [NSDictionary])?.compactMap { $0["id"] as? String }, ["camera", "mcp-pictures", "shout"])
        XCTAssertEqual((try json(messenger("tool", "shout"))["tools"] as? [NSDictionary])?.first?["name"] as? String, "say")
        XCTAssertEqual(try json(messenger("tool", "shout", "say", "--help"))["description"] as? String, "Shout it")

        let called = messenger("tool", "shout", "say", "--text", "hi", "--times", "2")
        XCTAssertEqual(called.exitCode, 0, called.standardError)
        XCTAssertEqual(((try json(called)["content"] as? [NSDictionary])?.first)?["text"] as? String, "HIHI")
    }

    func testToolErrorsExitNonZeroWithoutMessengerHelp() throws {
        let toolError = messenger("tool", "shout", "say")
        XCTAssertEqual(toolError.exitCode, 1)
        XCTAssertEqual(try json(toolError)["isError"] as? Bool, true)
        for failed in [messenger("tool", "shout", "say", "--times", "many"), messenger("tool", "missing"), messenger("tool", "shout", "nope")] {
            XCTAssertEqual(failed.exitCode, 2)
            XCTAssertTrue(failed.standardError.hasPrefix("messenger tool: "), failed.standardError)
            XCTAssertFalse(failed.standardError.contains("--list-conversations"), "tool failures must not print the Messenger reference")
        }
    }

    func testConnectionsReadAtFilesAsBase64AndEveryProvidersBinaryResultsBecomeFiles() throws {
        try Data("pixels".utf8).write(to: layout.workspace.appendingPathComponent("cat.png"))
        let connection = messenger("tool", "mcp-pictures", "describe", "--image", "@cat.png", "--note", "@@literal")
        XCTAssertEqual(connection.exitCode, 0, connection.standardError)
        let content = try XCTUnwrap(json(connection)["content"] as? [NSDictionary])
        XCTAssertEqual(content[0]["text"] as? String, "image=\(Data("pixels".utf8).base64EncodedString()) note=@literal")
        XCTAssertEqual(content[1]["type"] as? String, "file")
        let path = try XCTUnwrap(content[1]["path"] as? String)
        XCTAssertTrue(path.hasPrefix(layout.workspace.path + "/.noodle/tool-attachments/"), path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("PNG".utf8))
        XCTAssertNil(content[1]["data"], "the base64 is replaced by the file")

        // For Noodle's own tools an @ is ordinary text, but an image result is still a file.
        let camera = messenger("tool", "camera", "describe", "--image", "@cat.png")
        let cameraContent = try XCTUnwrap(json(camera)["content"] as? [NSDictionary])
        XCTAssertEqual(cameraContent[0]["text"] as? String, "image=@cat.png note=")
        XCTAssertEqual(cameraContent[1]["type"] as? String, "file")

        let raw = messenger("tool", "camera", "describe", "--raw")
        XCTAssertEqual((try json(raw)["content"] as? [NSDictionary])?[1]["type"] as? String, "image", "--raw keeps the result exactly as the tool returned it")
        XCTAssertEqual(messenger("tool", "mcp-pictures", "describe", "--image", "@../outside.png").exitCode, 2)
    }

    func testScriptOperationsUseTheSameBridgeFilesAndRulesAsTheCommandLine() throws {
        try Data("pixels".utf8).write(to: layout.workspace.appendingPathComponent("cat.png"))
        func run(_ action: MCPBridgeAction, tool: String? = nil, arguments: String? = nil, uri: String? = nil, raw: Bool = false) throws -> NSDictionary {
            let data = try ToolCLI.operation(action, provider: "mcp-pictures", tool: tool, arguments: arguments.map { Data($0.utf8) }, uri: uri, raw: raw,
                                             expandsFiles: true, workspace: layout.workspace, currentDirectory: layout.workspace)
            return try JSONSerialization.jsonObject(with: data) as! NSDictionary
        }
        XCTAssertEqual((try run(.tools)["tools"] as? [NSDictionary])?.first?["name"] as? String, "describe")
        XCTAssertNotNil(try run(.inspect, tool: "describe")["inputSchema"])
        let called = try XCTUnwrap(run(.call, tool: "describe", arguments: #"{"image":"@cat.png"}"#)["content"] as? [NSDictionary])
        XCTAssertEqual(called[0]["text"] as? String, "image=\(Data("pixels".utf8).base64EncodedString()) note=")
        XCTAssertEqual(called[1]["type"] as? String, "file")
        XCTAssertEqual((try run(.call, tool: "describe", raw: true)["content"] as? [NSDictionary])?[1]["type"] as? String, "image")
        // Resources are the connection's two extra tools; this stand-in has none, so the broker refuses.
        XCTAssertThrowsError(try run(.resources))
        XCTAssertThrowsError(try run(.readResource, uri: "x://1"))
        XCTAssertEqual(try ToolCLI.script(["mcp-pictures", "--run", "flow.js", "--timeout", "5"])?.mode, .run("flow.js"))
        XCTAssertEqual(try ToolCLI.script(["mcp-pictures", "--eval", "print(1)"])?.timeout, 300)
        XCTAssertNil(try ToolCLI.script(["mcp-pictures", "describe", "--run", "x"]), "after a tool name, --run is that tool's option")
        // Without a provider the script reaches every tool through `tools`.
        let free = try XCTUnwrap(ToolCLI.script(["--run", "flow.js", "--timeout", "9"]))
        XCTAssertNil(free.provider); XCTAssertEqual(free.mode, .run("flow.js")); XCTAssertEqual(free.timeout, 9)
        XCTAssertNil(try ToolCLI.script(["--eval", "1"])?.provider)
        XCTAssertEqual(try ToolCLI.kinds(workspace: layout.workspace, currentDirectory: layout.workspace),
                       ["camera": "extension", "mcp-pictures": "connection", "shout": "builtIn"])
        // "@" is a file reference for a connection and ordinary text for Noodle's own tools.
        let literal = try ToolCLI.operation(.call, provider: "camera", tool: "describe", arguments: Data(#"{"image":"@cat.png"}"#.utf8), uri: nil, raw: true,
                                            expandsFiles: false, workspace: layout.workspace, currentDirectory: layout.workspace)
        XCTAssertTrue(String(decoding: literal, as: UTF8.self).contains("image=@cat.png"))
        XCTAssertThrowsError(try ToolCLI.script(["mcp-pictures", "--eval", "1", "--timeout", "0"]))
        XCTAssertThrowsError(try ToolCLI.script(["mcp-pictures", "--run"]))
    }

    func testMessageTextNamedToolStillSendsAMessage() throws {
        // `tool` is only a command as the first word; elsewhere it is ordinary text.
        let result = messenger("--send", "--conversation", UUID().uuidString, "--body", "tool")
        XCTAssertFalse(result.standardError.hasPrefix("messenger tool: "), result.standardError)
    }
}
