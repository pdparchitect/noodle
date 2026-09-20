import XCTest
@testable import NoodleCore

/// A tool may hand Noodle something to post, but only into a conversation the broker
/// verified the calling bot belongs to. The provider here decides nothing.
final class ToolPostingTests: XCTestCase {
    private final class Cards: ToolProvider, @unchecked Sendable {
        let kind = ToolProviderKind.appExtension
        let manifest = ToolProviderManifest(id: "cards", title: "Cards", summary: "")
        var calls = 0
        var post: [String: Any]? = ["message": "Look", "attachment": ["filename": "page.card", "mediaType": "application/x-card", "data": Data("card".utf8).base64EncodedString()]]
        var duringCall: (() -> Void)?
        func tools(context: ToolCallContext) async throws -> Data {
            Data("""
            {"tools":[
              {"name":"present","inputSchema":{"type":"object","required":["conversation"],"properties":{
                 "conversation":{"type":"string","format":"noodle-conversation"},"message":{"type":"string"}}}},
              {"name":"sneaky","inputSchema":{"type":"object","properties":{"conversation":{"type":"string"}}}}]}
            """.utf8)
        }
        func call(_ tool: String, arguments: Data, files: [ToolFile], context: ToolCallContext) async throws -> Data {
            calls += 1
            duringCall?()
            var result: [String: Any] = ["content": [["type": "text", "text": "ok"]], "isError": false, "structuredContent": ["tabID": "T"]]
            if let post { result["_meta"] = ["noodle/post": post, "other": 1] }
            return try JSONSerialization.data(withJSONObject: result)
        }
    }
    private final class Host: @unchecked Sendable {
        let lock = NSLock()
        var members: Set<UUID> = []
        var posted: [(post: ToolPost, conversation: UUID)] = []
        let attachment = UUID()
        var services: ToolHostServices {
            ToolHostServices(isMember: { [self] _, conversation in lock.withLock { members.contains(conversation) } },
                             post: { [self] post, _, conversation in lock.withLock { posted.append((post, conversation)) }; return attachment })
        }
    }

    private let registry = ToolProviderRegistry()
    private let provider = Cards()
    private let host = Host()
    private let mine = UUID(), other = UUID()

    override func setUpWithError() throws { try registry.register(provider); host.members = [mine] }

    private func call(_ tool: String, _ arguments: [String: Any], services: ToolHostServices? = nil) async throws -> [String: Any] {
        let request = ToolBridgeRequest(session: "s", action: .call, provider: "cards", tool: tool, arguments: try JSONSerialization.data(withJSONObject: arguments))
        let data = try await ToolBroker.perform(request, registry: registry, assignments: { .none },
            context: ToolCallContext(agentID: UUID(), workspace: FileManager.default.temporaryDirectory), host: services ?? host.services)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAPostGoesOnlyToAConversationTheBotBelongsTo() async throws {
        let result = try await call("present", ["conversation": mine.uuidString.lowercased(), "message": "hi"])
        XCTAssertEqual(host.posted.count, 1)
        XCTAssertEqual(host.posted[0].conversation, mine)
        XCTAssertEqual(host.posted[0].post.message, "Look")
        XCTAssertEqual(host.posted[0].post.data, Data("card".utf8))
        XCTAssertEqual([host.posted[0].post.filename, host.posted[0].post.mediaType], ["page.card", "application/x-card"])
        XCTAssertEqual((result["structuredContent"] as? [String: Any])?["attachmentID"] as? String, host.attachment.uuidString)
        XCTAssertEqual((result["structuredContent"] as? [String: Any])?["tabID"] as? String, "T")
        XCTAssertNil((result["_meta"] as? [String: Any])?["noodle/post"], "the payload is consumed, not echoed to the bot")

        for refused in [["conversation": other.uuidString], ["conversation": "not-a-uuid"], ["conversation": 7], [:]] as [[String: Any]] {
            let before = provider.calls
            do { _ = try await call("present", refused); XCTFail("Expected a refusal for \(refused).") } catch {}
            XCTAssertEqual(provider.calls, before, "a refused conversation never reaches the provider")
        }
        XCTAssertEqual(host.posted.count, 1)
    }

    func testAToolThatDidNotDeclareAConversationCannotPost() async throws {
        do { _ = try await call("sneaky", ["conversation": mine.uuidString]); XCTFail("Expected the post to be refused.") } catch {}
        XCTAssertTrue(host.posted.isEmpty)
    }

    func testLeavingTheConversationDuringTheCallStopsThePost() async throws {
        provider.duringCall = { [host] in host.lock.withLock { host.members = [] } }
        do { _ = try await call("present", ["conversation": mine.uuidString]); XCTFail("Expected the post to be refused.") } catch {}
        XCTAssertTrue(host.posted.isEmpty)
    }

    func testMalformedOrOversizedPostsAreRefusedAndHostsWithoutPostingRefuseTheTool() async throws {
        for bad in [["attachment": ["filename": "", "mediaType": "a/b", "data": "AA=="]], ["attachment": ["filename": "a/b", "mediaType": "a/b", "data": "AA=="]],
                    ["attachment": ["filename": "a", "mediaType": "a/b", "data": "not base64!"]], ["message": "no attachment"]] as [[String: Any]] {
            provider.post = bad
            do { _ = try await call("present", ["conversation": mine.uuidString]); XCTFail("Expected a refusal for \(bad).") } catch {}
        }
        XCTAssertTrue(host.posted.isEmpty)
        provider.post = nil
        let plain = try await call("present", ["conversation": mine.uuidString])
        XCTAssertNil((plain["structuredContent"] as? [String: Any])?["attachmentID"], "a tool that posts nothing returns its result unchanged")
        let before = provider.calls
        do { _ = try await call("present", ["conversation": mine.uuidString], services: ToolHostServices.none); XCTFail("Expected a refusal.") } catch {}
        XCTAssertEqual(provider.calls, before)
    }
}
