import XCTest
@testable import NoodleCore

final class ToolProviderTests: XCTestCase {
    private struct Fixture: ToolProvider {
        let kind = ToolProviderKind.builtIn
        let manifest: ToolProviderManifest
        func tools(context: ToolCallContext) async throws -> Data { Data(#"{"tools":[]}"#.utf8) }
        func call(_ tool: String, arguments: Data, files: [ToolFile], context: ToolCallContext) async throws -> Data { arguments }
    }

    func testRegistryListsOnlyActiveProvidersAndRejectsDuplicatesAndBadNames() throws {
        let registry = ToolProviderRegistry()
        try registry.register(Fixture(manifest: .init(id: "vision", title: "Vision", summary: "")))
        try registry.register(Fixture(manifest: .init(id: "browser", title: "Browser", summary: "", activation: .whenAssigned("browser"))))
        XCTAssertEqual(registry.manifests(assignments: []).map(\.id), ["vision"])
        XCTAssertEqual(registry.manifests(assignments: ["browser"]).map(\.id), ["browser", "vision"])
        XCTAssertThrowsError(try registry.provider("browser", assignments: ["computer"]))
        XCTAssertThrowsError(try registry.provider("missing", assignments: []))
        XCTAssertNoThrow(try registry.provider("browser", assignments: ["browser"]))
        XCTAssertThrowsError(try registry.register(Fixture(manifest: .init(id: "vision", title: "Again", summary: ""))))
        for id in ["", "Vision", "a/b", "-a", "a-", String(repeating: "a", count: 49)] {
            XCTAssertThrowsError(try registry.register(Fixture(manifest: .init(id: id, title: "T", summary: ""))), id)
        }
        XCTAssertThrowsError(try registry.register(Fixture(manifest: .init(id: "x", title: "T", summary: "", activation: .init(rawValue: "sometimes")))))
        registry.unregister("vision")
        XCTAssertEqual(registry.manifests(assignments: ["browser"]).map(\.id), ["browser"])
    }

    func testManifestRoundTripsAsPlainJSON() throws {
        let manifest = ToolProviderManifest(id: "computer", title: "Computer", summary: "s", instructions: "i", activation: .whenAssigned("computer"))
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any]
        XCTAssertEqual(object?["activation"] as? String, "assigned:computer")
        XCTAssertEqual(try JSONDecoder().decode(ToolProviderManifest.self, from: JSONEncoder().encode(manifest)), manifest)
    }

    func testDescriptorReadsFileParametersTimeoutAndRetryHints() throws {
        let list = Data("""
        {"tools":[{"name":"ocr","description":"d","annotations":{"idempotentHint":true},"_meta":{"noodle/timeout":9000},
          "inputSchema":{"type":"object","properties":{
            "image":{"type":"string","format":"noodle-file"},
            "output":{"type":"string","format":"noodle-file","noodle/access":"write"},
            "language":{"type":"string"}}}},
         {"name":"click"}]}
        """.utf8)
        let tools = try ToolDescriptor.list(mcp: list)
        XCTAssertEqual(tools[0].fileParameters, [.init(name: "image", access: .read), .init(name: "output", access: .write)])
        XCTAssertEqual(tools[0].timeout, 3600)
        XCTAssertTrue(tools[0].retryable)
        XCTAssertEqual(tools[1].fileParameters, [])
        XCTAssertFalse(tools[1].retryable)
        XCTAssertThrowsError(try ToolDescriptor.list(mcp: Data(#"{"tools":[{"description":"nameless"}]}"#.utf8)))
        XCTAssertThrowsError(try ToolDescriptor(mcp: ["name": "x", "inputSchema": ["properties": ["f": ["format": "noodle-file", "noodle/access": "append"]]]]))
    }

    func testFileArgumentsStayInsideTheWorkspaceAndNeverReplaceOrFollowLinks() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace); try? FileManager.default.removeItem(at: outside) }
        try Data("picture".utf8).write(to: workspace.appendingPathComponent("sub/in.png"))
        try Data("secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("link.png"), withDestinationURL: outside)
        let tool = try ToolDescriptor(mcp: ["name": "t", "inputSchema": ["properties": [
            "image": ["format": "noodle-file"], "output": ["format": "noodle-file", "noodle/access": "write"]]]])
        func open(_ arguments: [String: Any], cwd: String = "") throws -> [ToolFile] {
            try ToolFileArguments.open(tool, arguments: JSONSerialization.data(withJSONObject: arguments),
                                       currentDirectory: workspace.appendingPathComponent(cwd), workspace: workspace)
        }

        let files = try open(["image": "in.png", "output": "out.txt", "other": 1], cwd: "sub")
        XCTAssertEqual(files.map(\.parameter), ["image", "output"])
        XCTAssertEqual(try files[0].handle.readToEnd(), Data("picture".utf8))
        try files[1].handle.write(contentsOf: Data("result".utf8))
        try files[1].handle.close()
        XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent("sub/out.txt")), Data("result".utf8))

        XCTAssertThrowsError(try open(["output": "sub/out.txt"]), "existing files are never replaced")
        XCTAssertThrowsError(try open(["image": "link.png"]), "symlinks are not followed")
        XCTAssertThrowsError(try open(["image": outside.path]))
        XCTAssertThrowsError(try open(["image": "sub/../sub/in.png"]))
        XCTAssertThrowsError(try open(["image": "sub"]), "directories are not files")
        XCTAssertThrowsError(try open(["image": 7]))
        XCTAssertTrue(try open([:]).isEmpty)
    }
}
