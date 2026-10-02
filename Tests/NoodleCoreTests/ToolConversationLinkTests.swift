import XCTest
@testable import NoodleCore

/// Folder arguments, links shared in a conversation, and results held back when the bot
/// leaves the conversation a call was made for.
final class ToolConversationLinkTests: XCTestCase {
    private final class Fixture: ToolProvider, @unchecked Sendable {
        let kind = ToolProviderKind.builtIn
        let manifest = ToolProviderManifest(id: "shared", title: "Shared", summary: "")
        var folders: [String] = []
        var calls = 0
        var during: (@Sendable () -> Void)?
        func tools(context: ToolCallContext) async throws -> Data {
            Data("""
            {"tools":[{"name":"open","inputSchema":{"type":"object","properties":{
              "path":{"type":"string","format":"noodle-file","noodle/access":"folder"},
              "link":{"type":"string","format":"noodle-conversation-link"},
              "conversation":{"type":"string","format":"noodle-conversation"}}}}]}
            """.utf8)
        }
        func call(_ tool: String, arguments: Data, files: [ToolFile], context: ToolCallContext) async throws -> Data {
            calls += 1
            for file in files where file.access == .folder {
                var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                XCTAssertEqual(fcntl(file.handle.fileDescriptor, F_GETPATH, &buffer), 0)
                folders.append(String(cString: buffer))
            }
            during?()
            return Data(#"{"content":[{"type":"text","text":"ok"}],"isError":false}"#.utf8)
        }
    }
    private final class Conversation: @unchecked Sendable {
        var members: Set<UUID> = []
        var posted: Set<String> = []
    }

    private var workspace: URL!
    private let registry = ToolProviderRegistry()
    private let fixture = Fixture()
    private let state = Conversation()
    private let agent = UUID(), conversation = UUID()

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("Game.noodlet"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: workspace.appendingPathComponent("file.txt"))
        try registry.register(fixture)
        state.members = [agent]
    }
    override func tearDown() { try? FileManager.default.removeItem(at: workspace) }

    private func open(_ arguments: [String: String]) async throws -> NSDictionary {
        let state = state
        let host = ToolHostServices(isMember: { agent, _ in state.members.contains(agent) },
                                    post: { _, _, _ in throw ToolProviderError("No posting here.") },
                                    isPosted: { link, agent, _ in state.members.contains(agent) && state.posted.contains(link.absoluteString) })
        let request = ToolBridgeRequest(session: "s", action: .call, provider: "shared", tool: "open",
                                        arguments: try JSONSerialization.data(withJSONObject: arguments))
        let data = try await ToolBroker.perform(request, registry: registry, assignments: { [:] },
                                                context: ToolCallContext(agentID: agent, workspace: workspace), host: host)
        return try JSONSerialization.jsonObject(with: data) as! NSDictionary
    }

    func testAFolderArgumentIsAFolderInTheWorkspaceAndNeverALink() async throws {
        _ = try await open(["path": "Game.noodlet"])
        let expected = realpath(workspace.appendingPathComponent("Game.noodlet").path, nil)
        defer { free(expected) }
        XCTAssertEqual(fixture.folders, [String(cString: expected!)])
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("Linked.noodlet"), withDestinationURL: outside)
        for refused in ["file.txt", "Linked.noodlet", "Missing.noodlet", outside.path, "../Game.noodlet"] {
            await assertRefused(try await self.open(["path": refused]))
        }
        XCTAssertEqual(fixture.calls, 1)
    }

    func testOnlyALinkSentInTheConversationReachesTheProvider() async throws {
        let link = "noodlet://\(UUID().uuidString.lowercased())"
        await assertRefused(try await self.open(["link": link, "conversation": self.conversation.uuidString]))
        await assertRefused(try await self.open(["link": link]))
        state.posted = [link]
        await assertRefused(try await self.open(["link": link]))
        let result = try await open(["link": link, "conversation": conversation.uuidString])
        XCTAssertEqual(result["isError"] as? Bool, false)
        state.members = []
        await assertRefused(try await self.open(["link": link, "conversation": self.conversation.uuidString]))
        XCTAssertEqual(fixture.calls, 1)
    }

    /// Whatever the tool found for a conversation the bot has since left stays with Noodle.
    func testLeavingTheConversationDuringTheCallWithholdsTheResult() async throws {
        let state = state, agent = agent
        fixture.during = { state.members.remove(agent) }
        await assertRefused(try await self.open(["conversation": self.conversation.uuidString]))
        XCTAssertEqual(fixture.calls, 1)
    }

    func testALinkNeedsAConversationToBeSharedIn() {
        let tool: [String: Any] = ["name": "open", "inputSchema": ["type": "object", "properties": [
            "link": ["type": "string", "format": "noodle-conversation-link"]]]]
        XCTAssertThrowsError(try ToolDescriptor(mcp: tool))
    }
}

private func assertRefused(_ expression: @autoclosure () async throws -> some Any, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("Expected the broker to refuse the call.", file: file, line: line) } catch {}
}
