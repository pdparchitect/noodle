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
        XCTAssertEqual((try json(providers)["providers"] as? [NSDictionary])?.first?["id"] as? String, "shout")
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

    func testMessageTextNamedToolStillSendsAMessage() throws {
        // `tool` is only a command as the first word; elsewhere it is ordinary text.
        let result = messenger("--send", "--conversation", UUID().uuidString, "--body", "tool")
        XCTAssertFalse(result.standardError.hasPrefix("messenger tool: "), result.standardError)
    }
}
