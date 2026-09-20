import BrowserBridge
import NoodleCore
import XCTest
@testable import NoodleBrowserTools

final class BrowserToolProviderTests: XCTestCase {
    private final class Transport: @unchecked Sendable {
        var requests: [BrowserRequest] = []
        var staged: [Data] = []
        var respond: (BrowserRequest, URL?) throws -> BrowserResponse = { _, _ in BrowserResponse() }
    }
    private let mine = UUID(), secret = UUID(), tab = UUID()
    private var root: URL!
    private var transport: Transport!
    private var provider: BrowserToolProvider!
    private let registry = ToolProviderRegistry()
    private let box = Posts()
    private final class Posts: @unchecked Sendable {
        private let lock = NSLock(); private var stored: [(post: ToolPost, conversation: UUID)] = []
        var values: [(post: ToolPost, conversation: UUID)] { lock.withLock { stored } }
        func add(_ post: ToolPost, _ conversation: UUID) -> UUID { lock.withLock { stored.append((post, conversation)) }; return UUID() }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("workspace"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("group"), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let transport = Transport(), group = root.appendingPathComponent("group")
        self.transport = transport
        provider = BrowserToolProvider(stagingRoot: { group }) { request in
            transport.requests.append(request)
            let payload = try request.transferID.map { try BrowserTransferFiles.staging(root: group, id: $0, create: false) }
            if let payload, let data = try? Data(contentsOf: payload) { transport.staged.append(data) }
            return try transport.respond(request, payload)
        }
        try registry.register(provider)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private var workspace: URL { root.appendingPathComponent("workspace") }
    private var posts: [(post: ToolPost, conversation: UUID)] = []
    private func call(_ tool: String, _ arguments: [String: Any], conversations: Set<UUID> = []) async throws -> [String: Any] {
        let request = ToolBridgeRequest(session: "s", action: .call, provider: provider.manifest.id, tool: tool,
                                        arguments: try JSONSerialization.data(withJSONObject: arguments))
        let data = try await ToolBroker.perform(request, registry: registry, assignments: { [mine] in ["browser": [mine.uuidString]] },
                                                context: ToolCallContext(agentID: UUID(), workspace: workspace),
                                                host: ToolHostServices(isMember: { _, id in conversations.contains(id) }, post: { [box] post, _, id in box.add(post, id) }))
        posts = box.values
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testPresentHandsNoodleACardForAConversationTheBrokerVerified() async throws {
        let conversation = UUID()
        transport.respond = { [mine, tab] _, _ in
            var response = BrowserResponse()
            var browser = RemoteBrowser(id: mine, name: "Work"); browser.description = "private note"
            response.reference = BrowserReference(browser: browser, tabID: tab, url: "https://example.com/a", title: "Pricing / Plans", previewImage: Data([1, 2, 3]))
            response.reference?.browser.description = "leaked by a decoded reference"
            return response
        }
        let result = try await call("present", ["browser": mine.uuidString, "tab": tab.uuidString, "conversation": conversation.uuidString], conversations: [conversation])
        XCTAssertEqual(result["isError"] as? Bool, false, String(describing: result["content"]))
        XCTAssertEqual((result["structuredContent"] as? [String: Any])?["tabID"] as? String, tab.uuidString)
        XCTAssertNotNil((result["structuredContent"] as? [String: Any])?["attachmentID"])
        XCTAssertFalse(String(describing: result).contains("previewImage"), "the snapshot stays in the attachment, out of the result")
        let post = try XCTUnwrap(posts.first)
        XCTAssertEqual([post.post.mediaType, post.post.filename, post.post.message], [BrowserReference.mediaType, "Pricing - Plans." + BrowserBuildIdentity.current.fileExtension, "Pricing / Plans"])
        let card = try BrowserReference.decode(post.post.data)
        XCTAssertEqual([card.browser.id, card.tabID], [mine, tab])
        XCTAssertNil(card.browser.description, "every conversation member can read a card")
        XCTAssertEqual(post.conversation, conversation)

        transport.respond = { [secret, tab] _, _ in
            var response = BrowserResponse()
            response.reference = BrowserReference(browser: RemoteBrowser(id: secret, name: "Bank"), tabID: tab, url: "https://bank.example", title: "Bank")
            return response
        }
        let swapped = try await call("present", ["browser": mine.uuidString, "tab": tab.uuidString, "conversation": conversation.uuidString], conversations: [conversation])
        XCTAssertEqual(swapped["isError"] as? Bool, true, "a reference for another browser or tab is never posted")
        XCTAssertEqual(posts.count, 1)
        do { _ = try await call("present", ["browser": mine.uuidString, "tab": tab.uuidString, "conversation": UUID().uuidString], conversations: [conversation]); XCTFail("Expected a refusal.") } catch {}
    }

    func testEveryOperationIsAToolBoundToAnAssignedBrowser() async throws {
        XCTAssertNoThrow(try provider.manifest.validate())
        XCTAssertEqual(provider.manifest.activation, .whenAssigned("browser"))
        let listed = try await provider.tools(context: .init(agentID: UUID(), workspace: workspace))
        let tools = try ToolDescriptor.list(mcp: listed)
        XCTAssertEqual(Set(tools.map(\.name)), Set(BrowserOperation.allCases.map(\.rawValue)))
        XCTAssertEqual(tools.first { $0.name == "present" }?.conversationParameter, "conversation")
        for tool in tools {
            XCTAssertFalse(tool.description.isEmpty, tool.name)
            if tool.name == "list" { XCTAssertEqual(tool.resourceList, ToolResourceList(kind: "browser", path: "browsers")) }
            else { XCTAssertEqual(tool.resourceParameters, [ToolResourceParameter(name: "browser", kind: "browser")], tool.name) }
        }
        XCTAssertEqual(tools.first { $0.name == "screenshot" }?.fileParameters, [ToolFileParameter(name: "output", access: .write)])
        XCTAssertEqual(tools.first { $0.name == "upload" }?.fileParameters, [ToolFileParameter(name: "source", access: .read)])
    }

    func testArgumentsBecomeTheSameRequestTheCommandLineBuilt() async throws {
        transport.respond = { [tab] _, _ in var response = BrowserResponse(); response.tabID = tab; return response }
        let result = try await call("click", ["browser": mine.uuidString.lowercased(), "tab": tab.uuidString, "target": "#buy", "count": 2, "frame": "f1"])
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual((result["structuredContent"] as? [String: Any])?["tabID"] as? String, tab.uuidString)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual([request.operation.rawValue, request.browserID?.uuidString, request.tabID?.uuidString, request.target, request.frame],
                       ["click", mine.uuidString, tab.uuidString, "#buy", "f1"])
        XCTAssertEqual(request.clickCount, 2)
        XCTAssertNil(request.transferID, "only a file transfer chooses a staging location")
    }

    func testUnassignedBrowsersNeverReachTheSocketAndListsAreFiltered() async throws {
        do { _ = try await call("tabs", ["browser": secret.uuidString]); XCTFail("Expected a refusal.") } catch {}
        XCTAssertTrue(transport.requests.isEmpty)
        transport.respond = { [mine, secret] _, _ in
            var response = BrowserResponse()
            response.browsers = [RemoteBrowser(id: mine, name: "Work"), RemoteBrowser(id: secret, name: "Bank")]
            return response
        }
        let result = try await call("list", [:])
        let browsers = (result["structuredContent"] as? [String: Any])?["browsers"] as? [[String: Any]]
        XCTAssertEqual(browsers?.compactMap { $0["name"] as? String }, ["Work"])
        XCTAssertFalse(String(describing: result["content"]).contains("Bank"))
    }

    func testInvalidRequestsAndBrowserErrorsAreToolErrors() async throws {
        let invalid = try await call("navigate", ["browser": mine.uuidString, "tab": tab.uuidString, "url": "file:///etc/hosts"])
        XCTAssertEqual(invalid["isError"] as? Bool, true)
        XCTAssertTrue(transport.requests.isEmpty, "validation happens before the socket")
        transport.respond = { _, _ in BrowserResponse(error: "That tab is closed.") }
        let failed = try await call("reload", ["browser": mine.uuidString, "tab": tab.uuidString])
        XCTAssertEqual(((failed["content"] as? [[String: Any]])?.first)?["text"] as? String, "That tab is closed.")
        // present without a conversation the broker verified never reaches the socket.
        let before = transport.requests.count
        do { _ = try await call("present", ["browser": mine.uuidString, "tab": tab.uuidString]); XCTFail("Expected a refusal.") } catch {}
        XCTAssertEqual(transport.requests.count, before)
    }

    func testUploadsStageTheWorkspaceFileAndDownloadsFillTheOutputFile() async throws {
        try Data("resume".utf8).write(to: workspace.appendingPathComponent("cv.pdf"))
        transport.respond = { request, _ in var response = BrowserResponse(); response.byteCount = 6; return response }
        let uploaded = try await call("upload", ["browser": mine.uuidString, "tab": tab.uuidString, "target": "input[type=file]", "source": "cv.pdf"])
        XCTAssertEqual(uploaded["isError"] as? Bool, false, String(describing: uploaded["content"]))
        XCTAssertEqual(transport.staged, [Data("resume".utf8)])
        XCTAssertEqual(transport.requests.last?.filename, "cv.pdf")

        transport.respond = { _, payload in
            try Data("PNGDATA".utf8).write(to: try XCTUnwrap(payload))
            var response = BrowserResponse(); response.byteCount = 7; return response
        }
        let shot = try await call("screenshot", ["browser": mine.uuidString, "tab": tab.uuidString, "output": "shot.png"])
        XCTAssertEqual(shot["isError"] as? Bool, false, String(describing: shot["content"]))
        XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent("shot.png")), Data("PNGDATA".utf8))

        transport.respond = { _, payload in
            try Data("short".utf8).write(to: try XCTUnwrap(payload))
            var response = BrowserResponse(); response.byteCount = 500; return response
        }
        let truncated = try await call("screenshot", ["browser": mine.uuidString, "tab": tab.uuidString, "output": "bad.png"])
        XCTAssertEqual(truncated["isError"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("bad.png").path), "a failed transfer leaves no file")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("group/file-transfers").path)
        XCTAssertEqual(leftovers, [], "staging is removed after every transfer")
    }

    func testScriptAndWebMCPOutputArrivesAsJSONAndAWebMCPErrorFailsTheCallWithItsDetails() async throws {
        transport.respond = { _, _ in var response = BrowserResponse(); response.text = #"{"title":"Docs","count":2}"#; return response }
        let evaluated = try await call("eval", ["browser": mine.uuidString, "tab": tab.uuidString, "text": "return 1"])
        let structured = try XCTUnwrap(evaluated["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["value"] as? NSDictionary, ["title": "Docs", "count": 2])
        XCTAssertNil(structured["text"], "the raw JSON string is replaced by its value")
        transport.respond = { _, _ in var response = BrowserResponse(); response.text = "true"; return response }
        let fragment = try await call("eval", ["browser": mine.uuidString, "tab": tab.uuidString, "text": "return true"])
        XCTAssertEqual((fragment["structuredContent"] as? [String: Any])?["value"] as? Bool, true)

        transport.respond = { _, _ in var response = BrowserResponse(); response.text = #"{"status":"error","error":{"code":"INVALID_ARGUMENTS","message":"count"}}"#; return response }
        let failed = try await call("webmcp-call", ["browser": mine.uuidString, "tab": tab.uuidString, "tool": "t1"])
        XCTAssertEqual(failed["isError"] as? Bool, true)
        let value = (failed["structuredContent"] as? [String: Any])?["value"] as? [String: Any]
        XCTAssertEqual((value?["error"] as? [String: Any])?["code"] as? String, "INVALID_ARGUMENTS")
        transport.respond = { _, _ in var response = BrowserResponse(); response.text = "Plain status text"; return response }
        let status = try await call("reload", ["browser": mine.uuidString, "tab": tab.uuidString])
        XCTAssertEqual((status["structuredContent"] as? [String: Any])?["text"] as? String, "Plain status text", "other tools keep text as text")
    }

    func testTheSkillCarriesTheBrowserGuidanceFromThisModule() {
        let instructions = provider.manifest.instructions
        XCTAssertTrue(instructions.contains("document.modelContext.executeTool"))
        XCTAssertTrue(instructions.contains("needs-user-action"))
        XCTAssertTrue(instructions.contains("messenger tool browser present"))
        XCTAssertFalse(instructions.contains("skills/browser/browser"), "nothing points bots at the removed command")
        for operation in BrowserOperation.allCases { XCTAssertFalse(BrowserToolGuidance.tool(operation).isEmpty, operation.rawValue) }
    }

    func testScriptsAndWebMCPArgumentsCanComeFromWorkspaceFiles() async throws {
        try Data("return document.title".utf8).write(to: workspace.appendingPathComponent("title.js"))
        _ = try await call("eval", ["browser": mine.uuidString, "tab": tab.uuidString, "file": "title.js"])
        XCTAssertEqual(transport.requests.last?.text, "return document.title")
        let both = try await call("eval", ["browser": mine.uuidString, "tab": tab.uuidString, "file": "title.js", "text": "1"])
        XCTAssertEqual(both["isError"] as? Bool, true)
        _ = try await call("webmcp-call", ["browser": mine.uuidString, "tab": tab.uuidString, "tool": "t1", "args": ["q": "noodles"]])
        XCTAssertEqual(transport.requests.last?.arguments, #"{"q":"noodles"}"#)
    }
}
