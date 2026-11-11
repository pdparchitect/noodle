import Foundation
import HubCore
import HubMac
import NoodleCore
@testable import NoodleMCP
import NoodleRuntime
import XCTest

/// Starting the Hub's bots hands each of them the applet tool while Noodle Applet is installed, and
/// stopping them takes it back. Built by hand rather than through `Hub`, whose Applet controller asks
/// whether this Mac has Noodle Applet.
@MainActor final class HubBotsStartTests: XCTestCase {
    func testStartingTheBotsGrantsThemTheAppletToolAndStoppingTakesItBack() throws {
        let (runtime, _) = try fakeRuntime()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-bots-start-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("Noodle"))
        try repository.prepare()
        let kai = try repository.createAgent(named: "Kai").agent
        let access = HubAccess(url: root.appendingPathComponent("access.json"))
        let tools = ToolProviderRegistry(), assignments = ToolAssignmentStore()
        let service = MCPService(credentials: NoCredentials(), oauth: MCPOAuth(), httpConfiguration: { .ephemeral })
        let connections = HubConnections(root: root, access: access, service: service, tools: tools, assignments: assignments)
        // Noodle Computer, Browser and Applet are never reached here.
        let computers = HubComputers(root: root, access: access, tools: tools, assignments: assignments,
                                     call: { _ in throw Unreachable() })
        let browsers = HubBrowsers(root: root, access: access, tools: tools, assignments: assignments,
                                   call: { _ in throw Unreachable() })
        let applets = AppletController(connection: { _ in throw Unreachable() }, isInstalled: { true })
        var grants: [[UUID: Set<String>]] = []
        applets.onGrantsChange = { grants.append($0) }
        let bots = HubBots(repository: repository, runtime: runtime, access: access, connections: connections,
                           computers: computers, browsers: browsers, applets: applets,
                           uploads: root.appendingPathComponent("Uploads", isDirectory: true),
                           readMarks: root.appendingPathComponent("read.json"), pins: nil, notifications: nil)

        try bots.start()
        XCTAssertEqual(grants.last, [kai.id: [AppletToolGrant.id]])
        bots.stop()
        XCTAssertEqual(grants.last, [:])
    }
}

private struct Unreachable: Error {}

/// A Keychain with no sign-ins, that takes none.
final class NoCredentials: MCPCredentialStorage, @unchecked Sendable {
    func load(_ id: UUID) throws -> MCPCredentials? { nil }
    func save(_ credentials: MCPCredentials, id: UUID) { XCTFail("These tests must never authorize an account") }
    func remove(_ id: UUID) throws {}
}
