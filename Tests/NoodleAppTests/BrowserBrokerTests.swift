import BrowserBridge
import Foundation
import NoodleCore
import XCTest
@testable import Noodle

/// Bots reach browsers through the Browser tool extension and Noodle's tool broker
/// (ToolResourceTests, BrowserToolProviderTests, ToolHostServicesTests). This controller
/// owns the assignments the broker enforces.
@MainActor final class BrowserBrokerTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let repository: WorkspaceRepository
        let agent: AgentRecord
        let controller: BrowserController
        let browser: UUID
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let group = root.appendingPathComponent("group")
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("library")); try repository.prepare()
        let agent = try repository.createAgent(named: "Browser test").agent
        let provider = BrowserTestProvider(root: group, blocked: false, wrongCount: false)
        let controller = BrowserController(repository: repository, connection: { try await provider.respond($0) })
        await controller.refresh()
        let browser = try XCTUnwrap(controller.registry.browsers.first?.id)
        addTeardownBlock { await provider.release(); try? FileManager.default.removeItem(at: root) }
        return .init(root: root, repository: repository, agent: agent, controller: controller, browser: browser)
    }
    func testAssignmentsArePublishedToTheToolBrokerAndAnUnreadableRegistryGrantsNothing() async throws {
        let f = try await fixture()
        var published: [[UUID: Set<String>]] = []
        f.controller.onAssignmentsChange = { published.append($0) }
        XCTAssertEqual(published, [[:]], "the current picture is published as soon as someone listens")
        try f.controller.assign([f.browser], to: f.agent)
        XCTAssertEqual(published.last, [f.agent.id: [f.browser.uuidString]])
        try f.controller.assign([], to: f.agent)
        XCTAssertEqual(published.last?[f.agent.id] ?? [], [])

        try f.controller.assign([f.browser], to: f.agent)
        try Data("not json".utf8).write(to: f.repository.rootURL.appendingPathComponent("browsers.json"))
        XCTAssertThrowsError(try f.controller.reloadAssignments())
        XCTAssertEqual(published.last, [:], "a registry that cannot be read must revoke, not keep, access")
    }
    func testSettingsCheckpointRestoresBrowserAssignments() async throws {
        let f = try await fixture()
        try f.controller.assign([f.browser], to: f.agent)
        let checkpoint = try AgentSettingsCheckpoint(repository: f.repository)
        try f.controller.assign([], to: f.agent)
        try checkpoint.restore(); try f.controller.reloadAssignments()
        XCTAssertEqual(f.controller.selectedIDs(for: f.agent), [f.browser])
    }
}
private actor BrowserTestProvider {
    static let bytes = Data([0, 1, 127, 128, 255])
    let root: URL
    var blocked: Bool
    let wrongCount: Bool
    let browsers = [RemoteBrowser(id: UUID(), name: "Assigned", description: "Company account."), RemoteBrowser(id: UUID(), name: "Private", description: "Personal banking.")]
    var gates: [CheckedContinuation<Void, Never>] = []
    private(set) var transfers: [BrowserRequest] = []
    private(set) var uploads: [Data] = []
    init(root: URL, blocked: Bool, wrongCount: Bool) { self.root = root; self.blocked = blocked; self.wrongCount = wrongCount }
    func release() { blocked = false; let pending = gates; gates = []; for gate in pending { gate.resume() } }
    func respond(_ request: BrowserRequest) async throws -> BrowserResponse {
        var response = BrowserResponse()
        if request.operation == .list { response.browsers = browsers; return response }
        if request.operation == .present {
            var reference = BrowserReference(browser: browsers[0], tabID: request.tabID!, url: "https://example.com", title: "Example")
            // A decoded companion response bypasses the initializer; the broker must still omit it.
            reference.browser.description = browsers[0].description
            response.reference = reference
            return response
        }
        guard request.operation.isFileTransfer else { return response }
        transfers.append(request)
        let file = try BrowserTransferFiles.staging(root: root, id: XCTUnwrap(request.transferID), create: false)
        if request.operation == .upload { let data = try Data(contentsOf: file); uploads.append(data); response.byteCount = Int64(data.count) }
        else { try Self.bytes.write(to: file); response.byteCount = Int64(Self.bytes.count) }
        if blocked { await withCheckedContinuation { gates.append($0) } }
        if wrongCount { response.byteCount! += 1 }
        return response
    }
}
