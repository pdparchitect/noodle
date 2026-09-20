import XCTest
@testable import NoodleCore

final class ToolBridgeTests: XCTestCase {
    private struct Echo: ToolProvider {
        let kind = ToolProviderKind.builtIn
        let manifest: ToolProviderManifest
        func tools(context: ToolCallContext) async throws -> Data {
            Data(#"{"tools":[{"name":"echo","inputSchema":{"type":"object","properties":{"text":{"type":"string"},"file":{"type":"string","format":"noodle-file"}}}}]}"#.utf8)
        }
        func call(_ tool: String, arguments: Data, files: [ToolFile], context: ToolCallContext) async throws -> Data {
            let text = try files.first?.handle.readToEnd().map { String(decoding: $0, as: UTF8.self) }
                ?? ((try JSONSerialization.jsonObject(with: arguments) as? [String: Any])?["text"] as? String ?? "")
            return try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": text]], "isError": false, "agent": context.agentID.uuidString])
        }
    }

    private var root: URL!
    private var caller: ToolBridgeAgent!
    private var other: ToolBridgeAgent!
    private var broker: ToolBridgeBroker!
    private let assignments = Assignments()
    private final class Assignments: @unchecked Sendable {
        private let lock = NSLock(); private var values: [UUID: ToolAssignments] = [:]
        subscript(id: UUID) -> ToolAssignments { get { lock.withLock { values[id] ?? .none } } set { lock.withLock { values[id] = newValue } } }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        caller = ToolBridgeAgent(id: UUID(), workspace: root.appendingPathComponent("caller"))
        other = ToolBridgeAgent(id: UUID(), workspace: root.appendingPathComponent("other"))
        for agent in [caller!, other!] { try FileManager.default.createDirectory(at: agent.workspace.appendingPathComponent("sub"), withIntermediateDirectories: true) }
        let registry = ToolProviderRegistry()
        try registry.register(Echo(manifest: .init(id: "echo", title: "Echo", summary: "")))
        try registry.register(Echo(manifest: .init(id: "browser", title: "Browser", summary: "", activation: .whenAssigned("browser"))))
        broker = ToolBridgeBroker(registry: registry) { [assignments] in assignments[$0] }
        try broker.start(agents: [caller, other])
    }
    override func tearDownWithError() throws { broker?.stop(); try? FileManager.default.removeItem(at: root) }

    private func request(_ action: ToolBridgeAction, provider: String? = nil, tool: String? = nil, arguments: String? = nil,
                         directory: String = "") throws -> NSDictionary {
        let data = try ToolBridgeClient.request(action, provider: provider, tool: tool, arguments: arguments.map { Data($0.utf8) },
            workspace: caller.workspace, currentDirectory: caller.workspace.appendingPathComponent(directory))
        return try JSONSerialization.jsonObject(with: data) as! NSDictionary
    }

    func testClientReachesProvidersThroughTheBrokerAsTheCallingAgent() throws {
        XCTAssertEqual((try request(.providers)["providers"] as? [NSDictionary])?.compactMap { $0["id"] as? String }, ["echo"])
        let result = try request(.call, provider: "echo", tool: "echo", arguments: #"{"text":"hi"}"#)
        XCTAssertEqual(result["agent"] as? String, caller.id.uuidString)
        XCTAssertEqual(((result["content"] as? [NSDictionary])?.first)?["text"] as? String, "hi")
    }

    func testFileArgumentsResolveAgainstTheCallersDirectory() throws {
        try Data("from file".utf8).write(to: caller.workspace.appendingPathComponent("sub/note.txt"))
        let result = try request(.call, provider: "echo", tool: "echo", arguments: #"{"file":"note.txt"}"#, directory: "sub")
        XCTAssertEqual(((result["content"] as? [NSDictionary])?.first)?["text"] as? String, "from file")
        try Data("secret".utf8).write(to: other.workspace.appendingPathComponent("secret.txt"))
        XCTAssertThrowsError(try request(.call, provider: "echo", tool: "echo",
            arguments: #"{"file":"\#(other.workspace.path)/secret.txt"}"#))
    }

    func testAssignmentChangesApplyWithoutRestartingTheBroker() throws {
        XCTAssertThrowsError(try request(.tools, provider: "browser"))
        assignments[caller.id] = ["browser": ["b1"]]
        XCTAssertNoThrow(try request(.tools, provider: "browser"))
        assignments[caller.id] = [:]
        XCTAssertThrowsError(try request(.tools, provider: "browser"))
    }

    func testAnotherAgentsSessionCannotAuthorizeARequest() throws {
        let stolen = try Data(contentsOf: other.workspace.appendingPathComponent(ToolBroker.path + "/session.json"))
        let mailbox = try WorkspaceMailbox(workspace: caller.workspace, path: ToolBroker.path)
        try mailbox.writeData(stolen, named: "session.json")
        XCTAssertThrowsError(try request(.providers)) { XCTAssertTrue($0.localizedDescription.contains("session"), $0.localizedDescription) }
    }

    func testMissingBridgeAndOversizedArgumentsFailBeforeAnyRequestIsWritten() throws {
        XCTAssertThrowsError(try request(.call, provider: "echo", tool: "echo",
            arguments: #"{"text":""# + String(repeating: "x", count: ToolBridgeClient.maxArgumentBytes) + #""}"#))
        XCTAssertEqual(try WorkspaceMailbox(workspace: caller.workspace, path: ToolBroker.path).names().filter { $0.hasSuffix(".request") }, [])
        broker.stop()
        try FileManager.default.removeItem(at: caller.workspace.appendingPathComponent(ToolBroker.path))
        XCTAssertThrowsError(try request(.providers))
    }
}
