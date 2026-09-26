import Foundation
import NoodleCore
import XCTest
@testable import Noodle
@testable import NoodleMCP
@testable import NoodleRuntimeSettings

/// Exercise the app controller and real workspace IPC. The service uses an empty
/// credential store, so broker rejection and reconnect paths need no accounts.
@MainActor final class MCPControllerTests: XCTestCase {
    private func fixture(credentialFailure: Bool = false, removed: XCTestExpectation? = nil) throws -> MCPControllerFixture {
        let f = try MCPControllerFixture(credentialFailure: credentialFailure, removed: removed)
        addTeardownBlock { @MainActor in
            f.controller.start(agents: [])
            f.stop()
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

    func testPresetRetryPreservesEditedAccountAndCannotOverwriteAnotherServer() throws {
        let f = try fixture()
        let configuration = MCPToolConfiguration(endpoint: URL(string: "https://example.com/mcp")!)
        let tool = ToolDefinition(id: "fixture", name: "Fixture", summary: "Fixture account", defaultInstructions: "",
            iconName: "tools", configuration: .mcp(configuration))
        var account = try f.controller.addPreset(tool, configuration: configuration)
        account.name = "Edited account"
        try f.controller.save(account)
        XCTAssertEqual(try f.controller.addPreset(tool, configuration: configuration, connectionID: account.id), account)
        let before = try Data(contentsOf: f.registryURL)
        let other = MCPToolConfiguration(endpoint: URL(string: "https://other.example.com/mcp")!)
        let different = ToolDefinition(id: "different", name: "Different", summary: "", defaultInstructions: "",
            iconName: "tools", configuration: .mcp(other))
        XCTAssertThrowsError(try f.controller.addPreset(different, configuration: other, connectionID: account.id))
        XCTAssertEqual(try Data(contentsOf: f.registryURL), before)
        XCTAssertEqual(f.controller.registry.connections, [account])
    }

    func testAssignmentAndRenameUpdateOnlyTheAssignedBotsInstructions() async throws {
        let f = try fixture(), account = try f.account()
        try f.start([f.a, f.b])
        try f.controller.save(account)
        try f.controller.assign([account.id], to: f.a)
        // A bot's instructions list the skills Noodle generated for it, shortly after the grant.
        try await f.waitUntil { (try? f.instructions(f.a).contains(account.name)) == true }
        XCTAssertFalse(try f.instructions(f.b).contains(account.name))
        var renamed = account
        renamed.name = "Renamed fixture tools"
        try f.controller.save(renamed)
        try await f.waitUntil { (try? f.instructions(f.a).contains(renamed.name)) == true }
        XCTAssertFalse(try f.instructions(f.a).contains(account.name))
        try f.controller.assign([], to: f.a)
        try await f.waitUntil { (try? f.instructions(f.a).contains(renamed.name)) == false }
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
        try f.start([f.a, f.b])
        f.controller.remove(account)
        // These assertions run before the asynchronous disconnect can execute.
        XCTAssertEqual(f.controller.registry.connections, [other])
        XCTAssertEqual(f.controller.selectedIDs(for: f.a), [other.id])
        XCTAssertTrue(f.controller.selectedIDs(for: f.b).isEmpty)
        XCTAssertEqual(try MCPRegistry.load(root: f.root), f.controller.registry)
        try await f.waitUntil { (try? f.instructions(f.a).contains(other.name)) == true && (try? f.instructions(f.a).contains(account.name)) == false }
        await fulfillment(of: [removed], timeout: 2)
        XCTAssertNil(f.controller.errorMessage)
    }

    func testASignInThatFailsToDeleteIsDeletedWhenNoodleNextStarts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-mcp-deletions-\(UUID())").resolvingSymlinksInPath()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let keychain = RefusingControllerCredentials()
        let service = MCPService(credentials: keychain, oauth: MCPOAuth(), httpConfiguration: { .ephemeral })
        let account = try MCPConnectionRecord(name: "Fixture tools", endpoint: URL(string: "https://example.com/mcp")!)
        let first = MCPController(repository: repository, service: service)
        try first.save(account)
        keychain.refusing = true
        first.remove(account)
        XCTAssertTrue(first.registry.connections.isEmpty, "Access must be revoked before the sign-in is deleted")
        for _ in 0..<200 where first.errorMessage == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(first.errorMessage)
        XCTAssertEqual(keychain.removed, [])

        keychain.refusing = false
        let next = MCPController(repository: repository, service: service)
        next.start(agents: [])
        for _ in 0..<200 where keychain.removed.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(keychain.removed, [account.id])
    }

    // The request files, sessions and clean-up now belong to the tool bridge every provider
    // shares. These tests drive it with this controller's real connections behind it.
    func testBridgeSessionsArePrivateStableAndRotatedAfterAnAgentIsRemoved() throws {
        let f = try fixture()
        try f.start([f.a, f.b])
        let first = try f.session(f.a), second = try f.session(f.b)
        XCTAssertFalse(first.token.isEmpty)
        XCTAssertNotEqual(first.token, second.token)
        XCTAssertEqual(first.processID, getpid())
        try f.start([f.a, f.b])
        XCTAssertEqual(try f.session(f.a).token, first.token)
        try f.start([f.b])
        try f.start([f.a, f.b])
        XCTAssertNotEqual(try f.session(f.a).token, first.token)
        XCTAssertEqual(try f.session(f.b).token, second.token)
    }

    func testForgedExpiredAndOversizedRequestsAreRejectedAndConsumed() async throws {
        let f = try fixture(), account = try f.account()
        try f.controller.save(account)
        try f.controller.assign([account.id], to: f.a)
        try f.start([f.a, f.b])
        try await f.skill(account, for: f.a)
        let reached = f.reach.count
        let session = try f.session(f.a).token
        let valid = ToolBridgeRequest(session: session, action: .tools, provider: account.skillName)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        let variants: [(String, Any)] = [
            ("id", UUID().uuidString), ("session", "forged"), ("session", try f.session(f.b).token),
            ("expiresAt", Date().addingTimeInterval(-1).timeIntervalSinceReferenceDate),
            ("expiresAt", Date().addingTimeInterval(600).timeIntervalSinceReferenceDate),
            ("tool", String(repeating: "é", count: 513)),
            ("provider", String(repeating: "x", count: 49)),
            ("currentDirectory", String(repeating: "x", count: 4097)),
            ("action", "unknown-action")
        ]
        for (field, value) in variants {
            var invalid = object
            invalid[field] = value
            let response = try await f.exchange(data: JSONSerialization.data(withJSONObject: invalid), id: valid.id)
            XCTAssertNotNil(response.error, field)
            XCTAssertNil(response.result, field)
            XCTAssertFalse(f.exists(valid.id, extension: "request"))
            XCTAssertFalse(f.exists(valid.id, extension: "running"))
        }
        // A file ID must also agree with the decoded request ID.
        object["session"] = session
        let mismatch = try await f.exchange(data: JSONSerialization.data(withJSONObject: object), id: UUID())
        XCTAssertNotNil(mismatch.error)
        for invalid in [Data("{unfinished JSON".utf8), Data(repeating: 65, count: 4 * 1_048_576)] {
            let response = try await f.exchange(data: invalid, id: UUID())
            XCTAssertNotNil(response.error)
        }
        XCTAssertEqual(f.reach.count, reached, "Invalid requests must not be dispatched to the service")
    }

    func testUnassignedAndUnknownConnectionsCannotReachTheService() async throws {
        let f = try fixture(), account = try f.account()
        try f.controller.save(account)
        try f.controller.assign([account.id], to: f.b)
        try f.start([f.a, f.b])
        try await f.skill(account, for: f.b)
        let reached = f.reach.count
        for provider in [account.skillName, "mcp-missing", account.id.uuidString.lowercased()] {
            let request = ToolBridgeRequest(session: try f.session(f.a).token, action: .tools, provider: provider)
            let response = try await f.exchange(request)
            XCTAssertNotNil(response.error, provider)
            XCTAssertNil(response.result)
            XCTAssertFalse(f.exists(request.id, extension: "running"))
        }
        XCTAssertEqual(f.reach.count, reached)
        // The bot it is assigned to reaches the service's sign-in gate.
        let granted = try await f.exchange(ToolBridgeRequest(session: try f.session(f.b).token, action: .tools, provider: account.skillName), agent: f.b)
        XCTAssertEqual(granted.error, MCPServiceError.signInRequired.localizedDescription)
        XCTAssertEqual(f.reach.count, reached + 1)
    }

    func testAssignedConnectionsReachTheServiceAndCannotReplay() async throws {
        let f = try fixture(), account = try f.account()
        try f.controller.save(account)
        try f.controller.assign([account.id], to: f.a)
        try f.start([f.a])
        let request = ToolBridgeRequest(session: try f.session(f.a).token, action: .tools, provider: account.skillName)
        let response = try await f.exchange(request)
        XCTAssertEqual(response.error, MCPServiceError.signInRequired.localizedDescription)
        try await f.waitUntil { f.controller.errors[account.id] == response.error }
        XCTAssertFalse(f.exists(request.id, extension: "running"))
        let replay = try await f.exchange(request)
        XCTAssertEqual(replay.error, "Invalid or expired tool session.", "An uncertain tool call must never be replayed")
    }

    func testUnexpectedServiceErrorsDoNotExposePrivateDetailsToTheBot() async throws {
        let f = try fixture(credentialFailure: true), account = try f.account()
        try f.controller.save(account)
        try f.controller.assign([account.id], to: f.a)
        try f.start([f.a])
        let response = try await f.exchange(ToolBridgeRequest(session: try f.session(f.a).token, action: .tools, provider: account.skillName))
        XCTAssertEqual(response.error, "The tool connection could not complete the request. Try reconnecting in Settings → Tools.")
        try await f.waitUntil { f.controller.errors[account.id] == response.error }
        XCTAssertNil(response.result)
    }

    func testRevokedAssignmentAndOldSessionAreRejectedOnLaterScans() async throws {
        let f = try fixture(), account = try f.account()
        try f.controller.save(account)
        try f.controller.assign([account.id], to: f.a)
        try f.start([f.a])
        let oldToken = try f.session(f.a).token
        try await f.skill(account, for: f.a)
        try f.controller.assign([], to: f.a)
        try await f.skill(account, for: f.a, exists: false)
        let reached = f.reach.count
        let response = try await f.exchange(ToolBridgeRequest(session: oldToken, action: .tools, provider: account.skillName))
        XCTAssertTrue(response.error?.contains("not assigned") == true, response.error ?? "no error")
        try f.start([])
        try f.start([f.a])
        XCTAssertEqual(f.reach.count, reached)
        try f.controller.assign([account.id], to: f.a)
        try await f.skill(account, for: f.a)
        let listed = f.reach.count
        let staleResponse = try await f.exchange(ToolBridgeRequest(session: oldToken, action: .tools, provider: account.skillName))
        XCTAssertEqual(staleResponse.error, "Invalid or expired tool session.")
        XCTAssertEqual(f.reach.count, listed)
    }

    func testScanCleansOnlyExpiredResponseAndRunningFilesWithRequestIDs() async throws {
        let f = try fixture()
        try f.start([f.a])
        let folder = f.folder(f.a), staleID = UUID().uuidString.lowercased(), recentID = UUID().uuidString.lowercased()
        for name in ["\(staleID).response", "\(staleID).running", "user-notes.response", "user-notes.running"] {
            let url = folder.appendingPathComponent(name)
            try Data("keep unless stale IPC".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: url.path)
        }
        let recent = folder.appendingPathComponent("\(recentID).response")
        try Data("recent response".utf8).write(to: recent)
        // A response to this request proves the scan has run; wait for all stale files too.
        _ = try await f.exchange(data: Data("invalid".utf8), id: UUID())
        try await f.waitUntil {
            !FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(staleID).response").path) &&
            !FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(staleID).running").path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("user-notes.response").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("user-notes.running").path))
    }
}

@MainActor final class MCPControllerFixture {
    let root: URL
    let repository: WorkspaceRepository
    let a: AgentRecord
    let b: AgentRecord
    let service: MCPService
    let controller: MCPController
    /// The same pieces the app wires together around this controller.
    let tools: ToolBridgeBroker
    let reach = MCPServiceReach()
    var registryURL: URL { root.appendingPathComponent("MCP/connections.json") }

    init(credentialFailure: Bool, removed: XCTestExpectation?) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-mcp-controller-\(UUID())").resolvingSymlinksInPath()
        repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        a = try repository.createAgent(named: "MCP A").agent
        b = try repository.createAgent(named: "MCP B").agent
        service = MCPService(credentials: EmptyControllerCredentials(fails: credentialFailure, removed: removed, reach: reach), oauth: MCPOAuth(),
            httpConfiguration: { XCTFail("An empty credential store must never start transport"); return .ephemeral })
        controller = MCPController(repository: repository, service: service)
        let assignments = ToolAssignmentStore(), registry = ToolProviderRegistry()
        let broker = ToolBridgeBroker(registry: registry) { assignments.assignments(for: $0) }
        tools = broker
        controller.toolRegistry = registry
        controller.onAssignmentsChange = { assignments.replace(ConnectionToolProvider.grantKind, with: $0); broker.synchronizeSkills() }
        let repository = repository, agents = [a, b]
        broker.onSkillsChanged = { id in
            Task { @MainActor in if let agent = agents.first(where: { $0.id == id }) { try? repository.synchronizeAgentWorkspace(agent) } }
        }
    }
    /// What the app does whenever its bots change.
    func start(_ agents: [AgentRecord]) throws {
        controller.start(agents: agents)
        try tools.start(agents: agents.map { ToolBridgeAgent(id: $0.id, workspace: repository.directory(for: $0)) })
    }
    func stop() { tools.stop() }
    /// Noodle lists a connection's tools to write its skill, which reaches the service once. Waiting for
    /// the skill leaves only the requests under test to move `reach`.
    func skill(_ account: MCPConnectionRecord, for agent: AgentRecord, exists: Bool = true) async throws {
        let file = repository.directory(for: agent).appendingPathComponent(".agents/skills/\(account.skillName)/SKILL.md")
        try await waitUntil { FileManager.default.fileExists(atPath: file.path) == exists }
    }

    func account(name: String = "Fixture tools") throws -> MCPConnectionRecord {
        try MCPConnectionRecord(name: name, endpoint: URL(string: "https://example.com/mcp")!)
    }
    func folder(_ agent: AgentRecord) -> URL { repository.directory(for: agent).appendingPathComponent(ToolBroker.path) }
    func session(_ agent: AgentRecord) throws -> MCPBridgeSession {
        try JSONDecoder().decode(MCPBridgeSession.self, from: Data(contentsOf: folder(agent).appendingPathComponent("session.json")))
    }
    func instructions(_ agent: AgentRecord) throws -> String {
        try String(contentsOf: repository.directory(for: agent).appendingPathComponent("AGENTS.md"), encoding: .utf8)
    }
    func file(_ id: UUID, extension suffix: String, agent: AgentRecord? = nil) -> URL {
        folder(agent ?? a).appendingPathComponent(id.uuidString.lowercased() + "." + suffix)
    }
    func exists(_ id: UUID, extension suffix: String) -> Bool {
        FileManager.default.fileExists(atPath: file(id, extension: suffix).path)
    }
    func exchange(_ request: ToolBridgeRequest, agent: AgentRecord? = nil) async throws -> ToolBridgeResponse {
        try await exchange(data: JSONEncoder().encode(request), id: request.id, agent: agent)
    }
    /// Written the way the real client writes it, so only what is under test can refuse it.
    func exchange(data: Data, id: UUID, agent: AgentRecord? = nil) async throws -> ToolBridgeResponse {
        let owner = agent ?? a, response = file(id, extension: "response", agent: owner)
        if FileManager.default.fileExists(atPath: response.path) { try FileManager.default.removeItem(at: response) }
        try WorkspaceMailbox(workspace: repository.directory(for: owner), path: ToolBroker.path)
            .writeData(data, named: id.uuidString.lowercased() + ".request")
        try await waitUntil {
            FileManager.default.fileExists(atPath: response.path) &&
                !FileManager.default.fileExists(atPath: self.file(id, extension: "running", agent: owner).path)
        }
        return try JSONDecoder().decode(ToolBridgeResponse.self, from: Data(contentsOf: response))
    }
    func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("MCP bridge did not finish before the test deadline")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Every request the service accepts starts by loading the connection's credentials.
final class MCPServiceReach: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

private struct EmptyControllerCredentials: MCPCredentialStorage {
    let fails: Bool
    let removed: XCTestExpectation?
    let reach: MCPServiceReach
    func load(_ id: UUID) throws -> MCPCredentials? {
        reach.increment()
        if fails { throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "private-token=secret-fixture"]) }
        return nil
    }
    func save(_ credentials: MCPCredentials, id: UUID) { XCTFail("These tests must never authorize an account") }
    func remove(_ id: UUID) { removed?.fulfill() }
}

/// A Keychain that refuses deletions until told otherwise, and records the ones it made.
private final class RefusingControllerCredentials: MCPCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var refusal = false, deleted: [UUID] = []
    var refusing: Bool { get { lock.withLock { refusal } } set { lock.withLock { refusal = newValue } } }
    var removed: [UUID] { lock.withLock { deleted } }
    func load(_ id: UUID) throws -> MCPCredentials? { nil }
    func save(_ credentials: MCPCredentials, id: UUID) { XCTFail("These tests must never authorize an account") }
    func remove(_ id: UUID) throws {
        try lock.withLock {
            if refusal { throw MCPServiceError.keychain(-25308) }
            deleted.append(id)
        }
    }
}
