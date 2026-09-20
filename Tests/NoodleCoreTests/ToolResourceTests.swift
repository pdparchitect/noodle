import XCTest
@testable import NoodleCore

/// A bot reaches only the resources Noodle assigned to it. Every check runs in the
/// broker; the provider here is deliberately naive and enforces nothing.
final class ToolResourceTests: XCTestCase {
    private final class Browsers: ToolProvider, @unchecked Sendable {
        let kind = ToolProviderKind.appExtension
        let manifest = ToolProviderManifest(id: "browser", title: "Browser", summary: "", activation: .whenAssigned("browser"))
        var received: [Data] = []
        var duringCall: (() -> Void)?
        func tools(context: ToolCallContext) async throws -> Data {
            Data("""
            {"tools":[
              {"name":"open","inputSchema":{"type":"object","required":["browser"],"properties":{
                 "browser":{"type":"string","format":"noodle-resource","noodle/kind":"browser"},"url":{"type":"string"},
                 "output":{"type":"string","format":"noodle-file","noodle/access":"write"}}}},
              {"name":"list","_meta":{"noodle/resource-list":{"kind":"browser","path":"browsers"}},"inputSchema":{"type":"object"}},
              {"name":"undeclared","inputSchema":{"type":"object","properties":{"browser":{"type":"string"}}}},
              {"name":"optional","inputSchema":{"type":"object","properties":{"browser":{"type":"string","format":"noodle-resource","noodle/kind":"browser"}}}}]}
            """.utf8)
        }
        func call(_ tool: String, arguments: Data, files: [ToolFile], context: ToolCallContext) async throws -> Data {
            received.append(arguments)
            duringCall?()
            for file in files where file.access == .write { try file.handle.write(contentsOf: Data("page".utf8)) }
            if tool == "list" {
                return Data(#"{"content":[{"type":"text","text":"MINE and SECRET"}],"isError":false,"structuredContent":{"browsers":[{"id":"mine","name":"Work"},{"id":"secret","name":"Bank"},{"name":"no id"}]}}"#.utf8)
            }
            return Data(#"{"content":[{"type":"text","text":"ok"}],"isError":false}"#.utf8)
        }
    }

    private var workspace: URL!
    private let registry = ToolProviderRegistry()
    private let provider = Browsers()
    private let assigned = Box(["browser": ["mine", "8E2B4C1A-0000-4000-8000-000000000001"]])
    private final class Box: @unchecked Sendable {
        private let lock = NSLock(); private var stored: ToolAssignments
        init(_ value: ToolAssignments) { stored = value }
        var value: ToolAssignments { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
    }

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try registry.register(provider)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: workspace) }

    private func call(_ tool: String, _ arguments: String) async throws -> [String: Any] {
        let request = ToolBridgeRequest(session: "s", action: .call, provider: "browser", tool: tool, arguments: Data(arguments.utf8))
        let data = try await ToolBroker.perform(request, registry: registry, assignments: { [assigned] in assigned.value },
                                                context: ToolCallContext(agentID: UUID(), workspace: workspace))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func refused(_ tool: String, _ arguments: String, file: StaticString = #filePath, line: UInt = #line) async {
        let before = provider.received.count
        do { _ = try await call(tool, arguments); XCTFail("Expected a refusal for \(arguments).", file: file, line: line) } catch {}
        XCTAssertEqual(provider.received.count, before, "A refused call must never reach the provider.", file: file, line: line)
    }

    func testOnlyAssignedResourcesReachTheProvider() async throws {
        _ = try await call("open", #"{"browser":"mine","url":"https://example.com"}"#)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: provider.received[0]) as? NSDictionary, ["browser": "mine", "url": "https://example.com"])
        await refused("open", #"{"browser":"secret"}"#)
        await refused("open", #"{"url":"https://example.com"}"#)
        await refused("open", #"{"browser":["mine","secret"]}"#)
        await refused("open", #"{"browser":null}"#)
        await refused("open", #"{"browser":""}"#)
    }

    func testIdentifiersMatchWithoutCaseAndAreForwardedAsAssigned() async throws {
        _ = try await call("open", #"{"browser":"8e2b4c1a-0000-4000-8000-000000000001"}"#)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: provider.received[0]) as? [String: Any])?["browser"] as? String,
                       "8E2B4C1A-0000-4000-8000-000000000001")
    }

    func testTheProviderSeesExactlyTheArgumentsTheBrokerChecked() async throws {
        // Parsers disagree about duplicate keys. Whatever the broker verified is re-encoded, so no second reading exists.
        do { _ = try await call("open", #"{"browser":"mine","browser":"secret"}"#) } catch {}
        do { _ = try await call("open", #"{"browser":"secret","browser":"mine"}"#) } catch {}
        for data in provider.received {
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret"), String(decoding: data, as: UTF8.self))
        }
    }

    func testToolsOnAnAssignedProviderMustDeclareTheirResource() async throws {
        await refused("undeclared", #"{"browser":"mine"}"#)
        await refused("optional", "{}")
        _ = try await call("optional", #"{"browser":"mine"}"#)
    }

    func testListsAreFilteredByTheBrokerInBothTextAndStructuredContent() async throws {
        let result = try await call("list", "{}")
        XCTAssertEqual((result["structuredContent"] as? [String: Any])?["browsers"] as? NSArray, [["id": "mine", "name": "Work"]])
        let text = ((result["content"] as? [[String: Any]])?.first)?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("Work"))
        XCTAssertFalse(text.contains("SECRET") || text.contains("Bank"), text)
    }

    func testRevocationDuringACallWithholdsTheResultAndItsFile() async throws {
        provider.duringCall = { [assigned] in assigned.value = [:] }
        do { _ = try await call("open", #"{"browser":"mine","output":"page.html"}"#); XCTFail("Expected the result to be withheld.") }
        catch { XCTAssertTrue(error.localizedDescription.contains("no longer assigned"), error.localizedDescription) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("page.html").path))
    }

    func testAssignmentsCrossTheExtensionBoundaryForProvidersThatFilterThemselves() throws {
        let context = ToolCallContext(agentID: UUID(), workspace: workspace, assignments: ["browser": ["mine"]])
        XCTAssertEqual(try JSONDecoder().decode(ToolAssignments.self, from: JSONEncoder().encode(context.assignments)), ["browser": ["mine"]])
        XCTAssertTrue(ToolAssignments(["browser": []]).ids("browser").isEmpty)
        XCTAssertFalse(ToolProviderRegistry.isActive(.whenAssigned("browser"), assignments: ["browser": []]))
    }
}
