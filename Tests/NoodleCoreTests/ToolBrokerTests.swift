import XCTest
@testable import NoodleCore

final class ToolBrokerTests: XCTestCase {
    private final class Fixture: ToolProvider, @unchecked Sendable {
        let kind = ToolProviderKind.appExtension
        let manifest: ToolProviderManifest
        var received: (tool: String, arguments: Data, files: [String])?
        var result = #"{"content":[{"type":"text","text":"ok"}],"isError":false}"#
        init(_ manifest: ToolProviderManifest) { self.manifest = manifest }
        func tools(context: ToolCallContext) async throws -> Data {
            Data("""
            {"tools":[{"name":"ocr","description":"Read text","inputSchema":{"type":"object","properties":{
              "image":{"type":"string","format":"noodle-file"},
              "output":{"type":"string","format":"noodle-file","noodle/access":"write"}}}}]}
            """.utf8)
        }
        func call(_ tool: String, arguments: Data, files: [ToolFile], context: ToolCallContext) async throws -> Data {
            received = (tool, arguments, files.map(\.parameter))
            for file in files where file.access == .write { try file.handle.write(contentsOf: Data("text".utf8)) }
            return Data(result.utf8)
        }
    }

    private var workspace: URL!
    private let registry = ToolProviderRegistry()
    private let vision = Fixture(.init(id: "vision", title: "Vision", summary: "On-device image tools"))
    private let browser = Fixture(.init(id: "browser", title: "Browser", summary: "", activation: .whenAssigned("browser")))

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("png".utf8).write(to: workspace.appendingPathComponent("sub/in.png"))
        try registry.register(vision)
        try registry.register(browser)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: workspace) }

    private func bridge(_ action: ToolBridgeAction, provider: String? = nil, tool: String? = nil, arguments: String? = nil,
                         directory: String = "", assignments: ToolAssignments = [:]) async throws -> NSDictionary {
        let request = ToolBridgeRequest(session: "s", action: action, provider: provider, tool: tool,
                                        arguments: arguments.map { Data($0.utf8) }, currentDirectory: directory)
        let data = try await ToolBroker.perform(request, registry: registry, assignments: { assignments },
                                                context: ToolCallContext(agentID: UUID(), workspace: workspace))
        return try JSONSerialization.jsonObject(with: data) as! NSDictionary
    }

    func testProvidersAndToolsFollowAssignments() async throws {
        let listed = try await bridge(.providers)
        XCTAssertEqual(listed, ["providers": [["id": "vision", "title": "Vision", "summary": "On-device image tools", "kind": "extension"]]])
        let assigned = try await bridge(.providers, assignments: ["browser": ["b1"]])
        XCTAssertEqual((assigned["providers"] as? [NSDictionary])?.compactMap { $0["id"] as? String }, ["browser", "vision"])
        let tools = try await bridge(.tools, provider: "vision")
        XCTAssertEqual(((tools["tools"] as? [NSDictionary])?.first)?["name"] as? String, "ocr")
        let inspected = try await bridge(.inspect, provider: "vision", tool: "ocr")
        XCTAssertEqual(inspected["description"] as? String, "Read text")
        await XCTAssertThrowsErrorAsync(try await self.bridge(.tools, provider: "browser"))
        await XCTAssertThrowsErrorAsync(try await self.bridge(.inspect, provider: "vision", tool: "missing"))
        await XCTAssertThrowsErrorAsync(try await self.bridge(.tools))
        await XCTAssertThrowsErrorAsync(try await self.bridge(.call, provider: "vision"))
    }

    func testCallOpensDeclaredFilesRelativeToTheCallersDirectory() async throws {
        let result = try await bridge(.call, provider: "vision", tool: "ocr",
                                       arguments: #"{"image":"in.png","output":"out.txt"}"#, directory: "sub")
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual(vision.received?.tool, "ocr")
        XCTAssertEqual(vision.received?.files, ["image", "output"])
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("sub/out.txt"), encoding: .utf8), "text")
    }

    func testFailedCallsLeaveNoOutputFileAndBadRequestsNeverReachTheProvider() async throws {
        vision.result = #"{"content":[{"type":"text","text":"no"}],"isError":true}"#
        let failed = try await bridge(.call, provider: "vision", tool: "ocr", arguments: #"{"output":"failed.txt"}"#)
        XCTAssertEqual(failed["isError"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("failed.txt").path))

        vision.received = nil
        await XCTAssertThrowsErrorAsync(try await self.bridge(.call, provider: "vision", tool: "ocr", arguments: #"{"image":"/etc/hosts"}"#))
        await XCTAssertThrowsErrorAsync(try await self.bridge(.call, provider: "vision", tool: "ocr", arguments: "[]"))
        await XCTAssertThrowsErrorAsync(try await self.bridge(.call, provider: "vision", tool: "nope", arguments: "{}"))
        await XCTAssertThrowsErrorAsync(try await self.bridge(.call, provider: "vision", tool: "ocr", arguments: "{}", directory: "../.."))
        XCTAssertNil(vision.received)
    }

    func testRequestRoundTripsThroughJSON() throws {
        let request = ToolBridgeRequest(session: "s", action: .call, provider: "vision", tool: "ocr", arguments: Data("{}".utf8), currentDirectory: "sub")
        let decoded = try JSONDecoder().decode(ToolBridgeRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.id, request.id)
        XCTAssertEqual(decoded.action, .call)
        XCTAssertEqual(decoded.currentDirectory, "sub")
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("Expected an error.", file: file, line: line) } catch {}
}

final class ToolBrokerTimeoutTests: XCTestCase {
    func testTheCallerGetsAnAnswerWhenAProviderNeverReturns() async throws {
        do {
            _ = try await ToolBroker.withTimeout(0.05, tool: "stuck") { try await Task.sleep(for: .seconds(3600)); return Data() }
            XCTFail("Expected a timeout.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("stuck timed out"), error.localizedDescription) }
        let value = try await ToolBroker.withTimeout(3600, tool: "quick") { Data("ok".utf8) }
        XCTAssertEqual(value, Data("ok".utf8))
    }
}
