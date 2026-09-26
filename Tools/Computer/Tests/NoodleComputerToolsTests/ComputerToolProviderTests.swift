import ComputerBridge
import NoodleCore
import XCTest
@testable import NoodleComputerTools

final class ComputerToolProviderTests: XCTestCase {
    private final class Transport: @unchecked Sendable {
        var requests: [ComputerRequest] = []
        var staged: [Data] = []
        var capabilities: ComputerCapabilities? = ComputerCapabilities()
        var respond: (ComputerRequest, URL?) throws -> ComputerResponse = { _, _ in ComputerResponse() }
    }
    private final class Posts: @unchecked Sendable {
        private let lock = NSLock(); private var stored: [(post: ToolPost, conversation: UUID)] = []
        private var revocations: [String] = []
        var values: [(post: ToolPost, conversation: UUID)] { lock.withLock { stored } }
        var revoked: [String] { lock.withLock { revocations } }
        func add(_ post: ToolPost, _ conversation: UUID) -> UUID { lock.withLock { stored.append((post, conversation)) }; return UUID() }
        func revoke(_ value: String) { lock.withLock { revocations.append(value) } }
    }
    private let mine = UUID(), secret = UUID(), terminal = UUID(), agent = UUID()
    private var root: URL!
    private var transport: Transport!
    private var provider: ComputerToolProvider!
    private let registry = ToolProviderRegistry()
    private let posts = Posts()
    private var assigned: ToolAssignments = [:]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("workspace"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("group"), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let transport = Transport(), group = root.appendingPathComponent("group")
        self.transport = transport
        assigned = ["computer": [mine.uuidString]]
        provider = ComputerToolProvider(stagingRoot: { group }) { request in
            // Every action is preceded by a capability handshake that never repeats a mutation.
            if request.operation == .list, request.capabilitiesOnly == true {
                var response = ComputerResponse(); response.capabilities = transport.capabilities; return response
            }
            transport.requests.append(request)
            let payload = try request.transferID.map { try ComputerTransferFiles.staging(root: group, id: $0, create: false) }
            if let payload, let data = try? Data(contentsOf: payload) { transport.staged.append(data) }
            var response = try transport.respond(request, payload)
            if request.operation == .list { response.capabilities = transport.capabilities }
            return response
        }
        try registry.register(provider)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private var workspace: URL { root.appendingPathComponent("workspace") }
    private func call(_ tool: String, _ arguments: [String: Any], conversations: Set<UUID> = [], during: (@Sendable () -> Void)? = nil) async throws -> [String: Any] {
        let request = ToolBridgeRequest(session: "s", action: .call, provider: "computer", tool: tool, arguments: try JSONSerialization.data(withJSONObject: arguments))
        let box = AssignmentBox(assigned)
        if let during { transport.respond = { [respond = transport.respond] request, payload in during(); box.value = [:]; return try respond(request, payload) } }
        let data = try await ToolBroker.perform(request, registry: registry, assignments: { box.value },
            context: ToolCallContext(agentID: agent, workspace: workspace),
            host: ToolHostServices(isMember: { _, id in conversations.contains(id) }, post: { [posts] post, _, id in posts.add(post, id) },
                                   revoked: { [posts] kind, id, agent in posts.revoke("\(kind):\(id):\(agent.uuidString)") }))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private final class AssignmentBox: @unchecked Sendable {
        private let lock = NSLock(); private var stored: ToolAssignments
        init(_ value: ToolAssignments) { stored = value }
        var value: ToolAssignments { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
    }

    func testOnlyBotOperationsAreToolsAndEachIsBoundToAnAssignedComputer() async throws {
        XCTAssertNoThrow(try provider.manifest.validate())
        XCTAssertEqual([provider.manifest.id, provider.manifest.activation.rawValue], ["computer", "assigned:computer"])
        let listed = try await provider.tools(context: .init(agentID: agent, workspace: workspace))
        let tools = try ToolDescriptor.list(mcp: listed)
        XCTAssertEqual(tools.map(\.name), ["list", "start", "open", "read", "write", "resize", "close", "present", "upload", "download"],
                       "revoke, display and terminalResolve stay user-only")
        for tool in tools {
            XCTAssertFalse(tool.description.isEmpty, tool.name)
            if tool.name == "list" { XCTAssertEqual(tool.resourceList, ToolResourceList(kind: "computer", path: "computers")) }
            else {
                XCTAssertEqual(tool.resourceParameters, [ToolResourceParameter(name: "computer", kind: "computer")], tool.name)
                XCTAssertTrue(tool.required.contains("computer"), tool.name)
            }
        }
        XCTAssertEqual(tools.first { $0.name == "upload" }?.fileParameters, [ToolFileParameter(name: "source", access: .read)])
        XCTAssertEqual(tools.first { $0.name == "download" }?.fileParameters, [ToolFileParameter(name: "destination", access: .write)])
        XCTAssertEqual(tools.first { $0.name == "present" }?.conversationParameter, "conversation")
    }

    func testListCarriesTheDescriptionAndPresentedCardsDoNot() async throws {
        let conversation = UUID()
        transport.respond = { [mine, terminal] request, _ in
            if request.operation == .list { return ComputerResponse(computers: [RemoteComputer(id: mine, name: "Build box", description: "Release builds only.", kind: "Shell", state: "Running", symbol: "terminal", hasWebDisplay: false)]) }
            var response = ComputerResponse(terminalID: terminal, data: Data("ok".utf8)); response.view = "terminal"; return response
        }
        let listed = try await call("list", [:])
        XCTAssertTrue(String(describing: listed["structuredContent"]).contains("Release builds only."))
        _ = try await call("present", ["computer": mine.uuidString, "terminal": terminal.uuidString, "conversation": conversation.uuidString], conversations: [conversation])
        let post = try XCTUnwrap(posts.values.first)
        XCTAssertFalse(String(decoding: post.post.data, as: UTF8.self).contains("Release builds only."), "every conversation member can read a card")
        XCTAssertTrue(provider.manifest.instructions.contains("choose by name, kind and description"))
        XCTAssertTrue(ComputerToolGuidance.tool("list").contains("description"))
    }

    func testTheSkillCarriesTheComputerGuidanceFromThisModule() {
        let instructions = provider.manifest.instructions
        XCTAssertTrue(instructions.contains("present --computer COMPUTER_ID --terminal"))
        XCTAssertTrue(instructions.contains("/opt/noodle-browser"))
        XCTAssertFalse(instructions.contains("skills/computer/computer"), "nothing points bots at the removed command")
    }

    func testTheOwnerOfATerminalIsTheCallingBotNeverAnArgument() async throws {
        transport.respond = { [terminal] _, _ in ComputerResponse(terminalID: terminal) }
        let opened = try await call("open", ["computer": mine.uuidString.lowercased(), "agentID": UUID().uuidString, "agent": UUID().uuidString])
        XCTAssertEqual((opened["structuredContent"] as? [String: Any])?["terminalID"] as? String, terminal.uuidString)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual([request.operation.rawValue, request.computerID?.uuidString, request.agentID?.uuidString], ["terminalOpen", mine.uuidString, agent.uuidString])
    }

    func testWriteSendsTextWithEnterOrExactBytesAndReadReturnsText() async throws {
        _ = try await call("write", ["computer": mine.uuidString, "terminal": terminal.uuidString, "text": "ls -la"])
        XCTAssertEqual(transport.requests.last?.data, Data("ls -la\r".utf8))
        _ = try await call("write", ["computer": mine.uuidString, "terminal": terminal.uuidString, "base64": "Aw=="])
        XCTAssertEqual(transport.requests.last?.data, Data([3]))
        for bad in [["text": "a", "base64": "Aw=="], [:], ["base64": "not base64"]] as [[String: Any]] {
            let count = transport.requests.count
            let result = try await call("write", ["computer": mine.uuidString, "terminal": terminal.uuidString].merging(bad) { $1 })
            XCTAssertEqual(result["isError"] as? Bool, true)
            XCTAssertEqual(transport.requests.count, count)
        }
        transport.respond = { _, _ in ComputerResponse(data: Data("total 0\n".utf8), offset: 8, truncated: false, exited: false) }
        let read = try await call("read", ["computer": mine.uuidString, "terminal": terminal.uuidString, "offset": 0])
        let structured = try XCTUnwrap(read["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["text"] as? String, "total 0\n")
        XCTAssertEqual(structured["offset"] as? Int, 8)
        XCTAssertNil(structured["data"], "valid UTF-8 output is not repeated as base64")
        XCTAssertEqual(transport.requests.last?.offset, 0)
        _ = try await call("resize", ["computer": mine.uuidString, "terminal": terminal.uuidString, "columns": 120, "rows": 40])
        XCTAssertEqual([transport.requests.last?.columns, transport.requests.last?.rows], [120, 40])
    }

    func testUnassignedComputersNeverReachTheSocketAndTheListIsFiltered() async throws {
        do { _ = try await call("start", ["computer": secret.uuidString]); XCTFail("Expected a refusal.") } catch {}
        XCTAssertTrue(transport.requests.isEmpty)
        transport.respond = { [mine, secret] _, _ in
            ComputerResponse(computers: [RemoteComputer(id: mine, name: "Build box", kind: "Shell", state: "Running", symbol: "terminal"),
                                         RemoteComputer(id: secret, name: "Finance", kind: "Desktop", state: "Running", symbol: "desktopcomputer")])
        }
        let result = try await call("list", [:])
        XCTAssertEqual(((result["structuredContent"] as? [String: Any])?["computers"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["Build box"])
        XCTAssertFalse(String(describing: result).contains("Finance"))
    }

    func testAnIncompatibleProviderIsReportedBeforeAnyAction() async throws {
        transport.capabilities = nil
        let result = try await call("start", ["computer": mine.uuidString])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertTrue((((result["content"] as? [[String: Any]])?.first)?["text"] as? String ?? "").contains("Update Noodle Computer"))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testTransfersStageInTheSharedGroupAndCheckSizes() async throws {
        try Data("wallpaper".utf8).write(to: workspace.appendingPathComponent("w.png"))
        transport.respond = { _, _ in var response = ComputerResponse(); response.byteCount = 9; response.path = "/workspace/w.png"; return response }
        let uploaded = try await call("upload", ["computer": mine.uuidString, "source": "w.png", "destination": "/workspace/w.png"])
        XCTAssertEqual(uploaded["isError"] as? Bool, false, String(describing: uploaded["content"]))
        XCTAssertEqual(transport.staged, [Data("wallpaper".utf8)])
        XCTAssertEqual([transport.requests.last?.path, (uploaded["structuredContent"] as? [String: Any])?["localPath"] as? String], ["/workspace/w.png", "w.png"])

        transport.respond = { _, payload in
            try Data("result".utf8).write(to: try XCTUnwrap(payload))
            var response = ComputerResponse(); response.byteCount = 6; return response
        }
        let downloaded = try await call("download", ["computer": mine.uuidString, "source": "/workspace/r.zip", "destination": "r.zip"])
        XCTAssertEqual(downloaded["isError"] as? Bool, false, String(describing: downloaded["content"]))
        XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent("r.zip")), Data("result".utf8))

        transport.respond = { _, payload in
            try Data("short".utf8).write(to: try XCTUnwrap(payload))
            var response = ComputerResponse(); response.byteCount = 5000; return response
        }
        let truncated = try await call("download", ["computer": mine.uuidString, "source": "/workspace/big", "destination": "big"])
        XCTAssertEqual(truncated["isError"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("big").path))
        let relative = try await call("upload", ["computer": mine.uuidString, "source": "w.png", "destination": "relative/path"])
        XCTAssertEqual(relative["isError"] as? Bool, true, "guest paths must be absolute")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("group/file-transfers").path), [])
    }

    func testPresentHandsNoodleACardAndRevocationDuringACallClosesTheBotsTerminals() async throws {
        let conversation = UUID()
        transport.respond = { [mine, terminal] request, _ in
            if request.operation == .list { return ComputerResponse(computers: [RemoteComputer(id: mine, name: "Build box", kind: "Shell", state: "Running", symbol: "terminal", hasWebDisplay: false)]) }
            var response = ComputerResponse(terminalID: terminal, data: Data("\u{1b}[32mok\u{1b}[0m done".utf8)); response.view = request.view ?? "terminal"; return response
        }
        let result = try await call("present", ["computer": mine.uuidString, "terminal": terminal.uuidString, "conversation": conversation.uuidString], conversations: [conversation])
        XCTAssertEqual(result["isError"] as? Bool, false, String(describing: result["content"]))
        let post = try XCTUnwrap(posts.values.first)
        XCTAssertEqual([post.post.mediaType, post.post.filename, post.post.message], [ComputerCard.mediaType, "Build box", "Open Build box"])
        let reference = try JSONDecoder().decode(ComputerReference.self, from: post.post.data)
        XCTAssertEqual([reference.computer.id, reference.terminalID], [mine, terminal])
        XCTAssertEqual(reference.terminalPreview, "ok done", "terminal colour codes are not stored in a card")
        XCTAssertEqual(transport.requests.first { $0.operation == .preview }?.agentID, agent)
        XCTAssertFalse(String(describing: result).contains("ok done"), "the preview stays in the card")

        let web = try await call("present", ["computer": mine.uuidString, "conversation": conversation.uuidString, "view": "web"], conversations: [conversation])
        XCTAssertEqual(web["isError"] as? Bool, true, "a shell-only computer has no web display")
        XCTAssertEqual(posts.values.count, 1)

        transport.respond = { [terminal] _, _ in ComputerResponse(terminalID: terminal) }
        do { _ = try await call("open", ["computer": mine.uuidString], during: {}); XCTFail("Expected the result to be withheld.") } catch {}
        XCTAssertEqual(posts.revoked, ["computer:\(mine.uuidString):\(agent.uuidString)"], "Noodle is told, so it can close what the call opened")
    }
}
