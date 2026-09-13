import Foundation
import NoodleCore
import XCTest
@testable import Noodle
@testable import NoodleMCP

/// Exercise the app controller and real workspace IPC. The service uses an empty
/// credential store, so broker rejection and reconnect paths need no accounts.
@MainActor final class MCPControllerTests: XCTestCase {
    private func fixture(credentialFailure: Bool = false, removed: XCTestExpectation? = nil) throws -> MCPControllerFixture {
        let f = try MCPControllerFixture(credentialFailure: credentialFailure, removed: removed)
        addTeardownBlock { @MainActor in
            f.controller.start(agents: [])
            try? FileManager.default.removeItem(at: f.root)
        }
        return f
    }

    func testSaveRenameAndReloadKeepAccountIdentityAndAssignments() throws {
        let f = try fixture()
        var account = try f.account()
        try f.controller.save(account)
        try f.controller.assign([account.id], to: f.a)
        account.name = "Renamed account"
        account.instructions = "Use the work account only."
        try f.controller.save(account)
        XCTAssertEqual(f.controller.registry.connections, [account])
        XCTAssertEqual(f.controller.selectedIDs(for: f.a), [account.id])
        XCTAssertTrue(f.controller.selectedIDs(for: f.b).isEmpty)
        let reloaded = MCPController(repository: f.repository, service: f.service)
        XCTAssertNil(reloaded.errorMessage)
        XCTAssertEqual(reloaded.registry, f.controller.registry)
        XCTAssertEqual(reloaded.selectedIDs(for: f.a), [account.id])
    }

    func testPresetsCreateIndependentAccountsAndRejectMismatchedSetup() throws {
        let f = try fixture()
        let configuration = MCPToolConfiguration(endpoint: URL(string: "https://example.com/mcp")!)
        let tool = ToolDefinition(id: "fixture", name: "Fixture", summary: "Fixture tools",
            defaultInstructions: "Keep accounts separate", iconName: "tools", configuration: .mcp(configuration))
        let first = try f.controller.addPreset(tool, configuration: configuration)
        let second = try f.controller.addPreset(tool, configuration: configuration)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.name, second.name)
        XCTAssertNotEqual(first.skillName, second.skillName)
        XCTAssertEqual(first.description, tool.summary)
        XCTAssertEqual(first.instructions, tool.defaultInstructions)
        XCTAssertEqual(first.endpoint, second.endpoint)
        XCTAssertTrue(f.controller.registry.assignments.isEmpty)
        XCTAssertTrue(f.controller.connected.isEmpty)
        let saved = try Data(contentsOf: f.registryURL)
        XCTAssertThrowsError(try f.controller.addPreset(tool,
            configuration: .init(endpoint: URL(string: "https://other.example.com/mcp")!)))
        XCTAssertEqual(try Data(contentsOf: f.registryURL), saved)
        XCTAssertEqual(f.controller.registry.connections, [first, second])
    }

    func testUnknownAssignmentPreservesSavedAndInMemorySelection() throws {
        let f = try fixture(), account = try f.account()
        try f.controller.save(account)
        try f.controller.assign([account.id], to: f.a)
        let saved = try Data(contentsOf: f.registryURL)
        XCTAssertThrowsError(try f.controller.assign([account.id, UUID()], to: f.a))
        XCTAssertEqual(try Data(contentsOf: f.registryURL), saved)
        XCTAssertEqual(f.controller.selectedIDs(for: f.a), [account.id])
        XCTAssertTrue(f.controller.selectedIDs(for: f.b).isEmpty)
    }

    func testAssignmentAndRenameUpdateOnlyTheAssignedBotsInstructions() throws {
        let f = try fixture(), account = try f.account()
        f.controller.start(agents: [f.a, f.b])
        try f.controller.save(account)
        try f.controller.assign([account.id], to: f.a)
        XCTAssertTrue(try f.instructions(f.a).contains(account.name))
        XCTAssertFalse(try f.instructions(f.b).contains(account.name))
        var renamed = account
        renamed.name = "Renamed fixture tools"
        try f.controller.save(renamed)
        XCTAssertTrue(try f.instructions(f.a).contains(renamed.name))
        XCTAssertFalse(try f.instructions(f.a).contains(account.name))
        try f.controller.assign([], to: f.a)
        XCTAssertFalse(try f.instructions(f.a).contains(renamed.name))
    }

    func testUnreadableRegistryBlocksAllMutationsWithoutOverwritingIt() throws {
        let f = try fixture(), account = try f.account()
        try f.controller.save(account)
        let damaged = Data("{ damaged registry with recoverable user data".utf8)
        try damaged.write(to: f.registryURL)
        let controller = MCPController(repository: f.repository, service: f.service)
        XCTAssertTrue(controller.errorMessage?.contains("have not been replaced") == true)
        XCTAssertThrowsError(try controller.save(account))
        XCTAssertThrowsError(try controller.validateAssignment([]))
        XCTAssertThrowsError(try controller.assign([], to: f.a))
        controller.remove(account)
        XCTAssertTrue(controller.errorMessage?.contains("Restore the registry") == true)
        XCTAssertEqual(try Data(contentsOf: f.registryURL), damaged)
        XCTAssertTrue(controller.registry.connections.isEmpty)
    }

    func testFailedRegistryWritesDoNotPublishSaveAssignmentOrRemoval() throws {
        let f = try fixture(), account = try f.account()
        try f.controller.save(account)
        try f.controller.assign([account.id], to: f.a)
        let before = f.controller.registry
        // A directory at the destination forces atomic writes to fail even as root.
        try FileManager.default.removeItem(at: f.registryURL)
        try FileManager.default.createDirectory(at: f.registryURL, withIntermediateDirectories: false)
        var renamed = account
        renamed.name = "Cannot persist this"
        XCTAssertThrowsError(try f.controller.save(renamed))
        XCTAssertEqual(f.controller.registry, before)
        XCTAssertThrowsError(try f.controller.assign([], to: f.a))
        XCTAssertEqual(f.controller.registry, before)
        f.controller.remove(account)
        XCTAssertNotNil(f.controller.errorMessage)
        XCTAssertEqual(f.controller.registry, before)
    }

    func testRemovalRevokesEveryAssignmentAndPersistsBeforeCredentialCleanup() async throws {
        let removed = expectation(description: "Credentials removed")
        let f = try fixture(removed: removed), account = try f.account(), other = try f.account(name: "Other tools")
        try f.controller.save(account)
        try f.controller.save(other)
        try f.controller.assign([account.id, other.id], to: f.a)
        try f.controller.assign([account.id], to: f.b)
        f.controller.start(agents: [f.a, f.b])
        f.controller.remove(account)
        // These assertions run before the asynchronous disconnect can execute.
        XCTAssertEqual(f.controller.registry.connections, [other])
        XCTAssertEqual(f.controller.selectedIDs(for: f.a), [other.id])
        XCTAssertTrue(f.controller.selectedIDs(for: f.b).isEmpty)
        XCTAssertEqual(try MCPRegistry.load(root: f.root), f.controller.registry)
        XCTAssertFalse(try f.instructions(f.a).contains(account.name))
        XCTAssertTrue(try f.instructions(f.a).contains(other.name))
        await fulfillment(of: [removed], timeout: 2)
        XCTAssertNil(f.controller.errorMessage)
    }

    func testBridgeSessionsArePrivateStableAndRotatedAfterAnAgentIsRemoved() throws {
        let f = try fixture()
        f.controller.start(agents: [f.a, f.b])
        let first = try f.session(f.a), second = try f.session(f.b)
        XCTAssertFalse(first.token.isEmpty)
        XCTAssertNotEqual(first.token, second.token)
        XCTAssertEqual(first.processID, getpid())
        f.controller.start(agents: [f.a, f.b])
        XCTAssertEqual(try f.session(f.a).token, first.token)
        f.controller.start(agents: [f.b])
        f.controller.start(agents: [f.a, f.b])
        XCTAssertNotEqual(try f.session(f.a).token, first.token)
        XCTAssertEqual(try f.session(f.b).token, second.token)
    }

    func testForgedExpiredAndOversizedRequestsAreRejectedAndConsumed() async throws {
        let f = try fixture(), account = try f.account()
        try f.controller.save(account)
        try f.controller.assign([account.id], to: f.a)
        f.controller.start(agents: [f.a, f.b])
        let session = try f.session(f.a).token
        let valid = MCPBridgeRequest(session: session, connectionID: account.id, action: .tools, tool: nil, arguments: nil)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        let variants: [(String, Any)] = [
            ("id", UUID().uuidString), ("session", "forged"), ("session", try f.session(f.b).token),
            ("expiresAt", Date().addingTimeInterval(-1).timeIntervalSinceReferenceDate),
            ("expiresAt", Date().addingTimeInterval(600).timeIntervalSinceReferenceDate),
            ("tool", String(repeating: "é", count: 513)),
            ("skillName", String(repeating: "x", count: 65)),
            ("arguments", Data(repeating: 65, count: MCPBridgeFiles.maxRequestBytes + 1).base64EncodedString()),
            ("action", "unknown-action")
        ]
        for (field, value) in variants {
            var invalid = object
            invalid[field] = value
            let response = try await f.exchange(data: JSONSerialization.data(withJSONObject: invalid), id: valid.id)
            XCTAssertEqual(response.error, "Expired or invalid MCP request.", field)
            XCTAssertNil(response.result)
            XCTAssertFalse(f.exists(valid.id, extension: "request"))
            XCTAssertFalse(f.exists(valid.id, extension: "running"))
        }
        // A file ID must also agree with the decoded request ID.
        object["session"] = session
        let mismatch = try await f.exchange(data: JSONSerialization.data(withJSONObject: object), id: UUID())
        XCTAssertEqual(mismatch.error, "Expired or invalid MCP request.")
        for invalid in [Data("{unfinished JSON".utf8), Data(repeating: 65, count: MCPBridgeFiles.maxRequestEnvelopeBytes + 1)] {
            let response = try await f.exchange(data: invalid, id: UUID())
            XCTAssertEqual(response.error, "Expired or invalid MCP request.")
        }
        XCTAssertTrue(f.controller.errors.isEmpty, "Invalid requests must not be dispatched to the service")
    }

    func testUnassignedAndAmbiguousConnectionsCannotReachTheService() async throws {
        let f = try fixture(), account = try f.account()
        try f.controller.save(account)
        try f.controller.assign([account.id], to: f.b)
        f.controller.start(agents: [f.a, f.b])
        let selectors: [(UUID?, String?)] = [(account.id, nil), (nil, account.skillName),
            (UUID(), nil), (nil, "mcp-missing"), (nil, nil), (account.id, account.skillName)]
        for (id, skill) in selectors {
            let request = MCPBridgeRequest(session: try f.session(f.a).token, connectionID: id, skillName: skill,
                action: .tools, tool: nil, arguments: nil)
            let response = try await f.exchange(request)
            XCTAssertEqual(response.error, "This MCP connection is not assigned to this bot.")
            XCTAssertNil(response.result)
            XCTAssertFalse(f.exists(request.id, extension: "running"))
        }
        XCTAssertTrue(f.controller.errors.isEmpty)
    }

    func testAssignedConnectionsReachServiceByIDOrSkillAndCannotReplay() async throws {
        let f = try fixture(), account = try f.account()
        try f.controller.save(account)
        try f.controller.assign([account.id], to: f.a)
        f.controller.start(agents: [f.a])
        for bySkill in [false, true] {
            let request = MCPBridgeRequest(session: try f.session(f.a).token,
                connectionID: bySkill ? nil : account.id, skillName: bySkill ? account.skillName : nil,
                action: .call, tool: "echo", arguments: Data("{}".utf8))
            let response = try await f.exchange(request)
            XCTAssertEqual(response.error, MCPServiceError.signInRequired.localizedDescription)
            XCTAssertEqual(f.controller.errors[account.id], response.error)
            XCTAssertFalse(f.exists(request.id, extension: "running"))
            let replay = try await f.exchange(request)
            XCTAssertEqual(replay.error, "Expired or invalid MCP request.", "An uncertain tool call must never be replayed")
        }
    }

    func testUnexpectedServiceErrorsDoNotExposePrivateDetailsToTheBot() async throws {
        let f = try fixture(credentialFailure: true), account = try f.account()
        try f.controller.save(account)
        try f.controller.assign([account.id], to: f.a)
        f.controller.start(agents: [f.a])
        let request = MCPBridgeRequest(session: try f.session(f.a).token, connectionID: account.id,
            action: .tools, tool: nil, arguments: nil)
        let response = try await f.exchange(request)
        XCTAssertEqual(response.error, "The tool connection could not complete the request. Try reconnecting in Settings → Tools.")
        XCTAssertEqual(f.controller.errors[account.id], response.error)
        XCTAssertNil(response.result)
    }

    func testRevokedAssignmentAndOldSessionAreRejectedOnLaterScans() async throws {
        let f = try fixture(), account = try f.account()
        try f.controller.save(account)
        try f.controller.assign([account.id], to: f.a)
        f.controller.start(agents: [f.a])
        let oldToken = try f.session(f.a).token
        try f.controller.assign([], to: f.a)
        let revoked = MCPBridgeRequest(session: oldToken, connectionID: account.id, action: .tools, tool: nil, arguments: nil)
        let response = try await f.exchange(revoked)
        XCTAssertEqual(response.error, "This MCP connection is not assigned to this bot.")
        f.controller.start(agents: [])
        f.controller.start(agents: [f.a])
        try f.controller.assign([account.id], to: f.a)
        let stale = MCPBridgeRequest(session: oldToken, connectionID: account.id, action: .tools, tool: nil, arguments: nil)
        let staleResponse = try await f.exchange(stale)
        XCTAssertEqual(staleResponse.error, "Expired or invalid MCP request.")
        XCTAssertTrue(f.controller.errors.isEmpty)
    }

    func testScanCleansOnlyExpiredResponseAndRunningFilesWithRequestIDs() async throws {
        let f = try fixture()
        f.controller.start(agents: [f.a])
        let folder = f.folder(f.a), staleID = UUID(), recentID = UUID()
        for name in ["\(staleID.uuidString).response", "\(staleID.uuidString).running", "user-notes.response", "user-notes.running"] {
            let url = folder.appendingPathComponent(name)
            try Data("keep unless stale IPC".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: url.path)
        }
        let recent = folder.appendingPathComponent("\(recentID.uuidString).response")
        try Data("recent response".utf8).write(to: recent)
        // A response to this request proves the scan has run; wait for all stale files too.
        _ = try await f.exchange(data: Data("invalid".utf8), id: UUID())
        try await f.waitUntil {
            !FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(staleID.uuidString).response").path) &&
            !FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(staleID.uuidString).running").path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("user-notes.response").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("user-notes.running").path))
    }
}

@MainActor private final class MCPControllerFixture {
    let root: URL
    let repository: WorkspaceRepository
    let a: AgentRecord
    let b: AgentRecord
    let service: MCPService
    let controller: MCPController
    var registryURL: URL { root.appendingPathComponent("MCP/connections.json") }

    init(credentialFailure: Bool, removed: XCTestExpectation?) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-mcp-controller-\(UUID())").resolvingSymlinksInPath()
        repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        a = try repository.createAgent(named: "MCP A").agent
        b = try repository.createAgent(named: "MCP B").agent
        service = MCPService(credentials: EmptyControllerCredentials(fails: credentialFailure, removed: removed), oauth: MCPOAuth(),
            httpConfiguration: { XCTFail("An empty credential store must never start transport"); return .ephemeral })
        controller = MCPController(repository: repository, service: service)
    }

    func account(name: String = "Fixture tools") throws -> MCPConnectionRecord {
        try MCPConnectionRecord(name: name, endpoint: URL(string: "https://example.com/mcp")!)
    }
    func folder(_ agent: AgentRecord) -> URL { MCPBridgeFiles.directory(workspace: repository.directory(for: agent)) }
    func session(_ agent: AgentRecord) throws -> MCPBridgeSession {
        try JSONDecoder().decode(MCPBridgeSession.self, from: Data(contentsOf: folder(agent).appendingPathComponent("session.json")))
    }
    func instructions(_ agent: AgentRecord) throws -> String {
        try String(contentsOf: repository.directory(for: agent).appendingPathComponent("AGENTS.md"), encoding: .utf8)
    }
    func file(_ id: UUID, extension suffix: String) -> URL {
        folder(a).appendingPathComponent(id.uuidString.lowercased() + "." + suffix)
    }
    func exists(_ id: UUID, extension suffix: String) -> Bool {
        FileManager.default.fileExists(atPath: file(id, extension: suffix).path)
    }
    func exchange(_ request: MCPBridgeRequest) async throws -> MCPBridgeResponse {
        try await exchange(data: JSONEncoder().encode(request), id: request.id)
    }
    func exchange(data: Data, id: UUID) async throws -> MCPBridgeResponse {
        let response = file(id, extension: "response")
        if FileManager.default.fileExists(atPath: response.path) { try FileManager.default.removeItem(at: response) }
        try data.write(to: file(id, extension: "request"), options: .atomic)
        try await waitUntil { self.exists(id, extension: "response") && !self.exists(id, extension: "running") }
        return try JSONDecoder().decode(MCPBridgeResponse.self, from: Data(contentsOf: response))
    }
    func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("MCP bridge did not finish before the test deadline")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct EmptyControllerCredentials: MCPCredentialStorage {
    let fails: Bool
    let removed: XCTestExpectation?
    func load(_ id: UUID) throws -> MCPCredentials? {
        if fails { throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "private-token=secret-fixture"]) }
        return nil
    }
    func save(_ credentials: MCPCredentials, id: UUID) { XCTFail("These tests must never authorize an account") }
    func remove(_ id: UUID) { removed?.fulfill() }
}
