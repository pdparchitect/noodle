import BrowserBridge
import Foundation
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class BrowserBrokerTests: XCTestCase {
    private struct Fixture {
        let root: URL, group: URL
        let repository: WorkspaceRepository
        let agent: AgentRecord
        let controller: BrowserController
        let provider: BrowserTestProvider
        let browser: UUID
        let token: String
        func envelope(_ operation: BrowserOperation, path: String? = nil) -> BrowserAgentRequest {
            var request = BrowserRequest(operation, browserID: operation == .list ? nil : browser, tabID: UUID())
            request.fileID = UUID(); request.target = "#file"
            return .init(token: token, request: request, localPath: path)
        }
        func local(_ path: String) -> URL { repository.directory(for: agent).appendingPathComponent(path) }
    }
    private func fixture(blocked: Bool = false, wrongCount: Bool = false) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let group = root.appendingPathComponent("group")
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("library")); try repository.prepare()
        let agent = try repository.createAgent(named: "Browser test").agent
        let provider = BrowserTestProvider(root: group, blocked: blocked, wrongCount: wrongCount)
        let controller = BrowserController(repository: repository, transferRoot: group, connection: { try await provider.respond($0) })
        await controller.refresh()
        let browser = try XCTUnwrap(controller.registry.browsers.first?.id)
        try controller.assign([browser], to: agent)
        controller.start(agents: [agent], monitoring: false)
        let directory = try BrowserAgentSkill.bridge(workspace: repository.directory(for: agent))
        let token = try JSONDecoder().decode(MCPBridgeSession.self, from: Data(contentsOf: directory.appendingPathComponent("session.json"))).token
        addTeardownBlock { await provider.release(); await MainActor.run { controller.start(agents: [], monitoring: false) }; try? FileManager.default.removeItem(at: root) }
        return .init(root: root, group: group, repository: repository, agent: agent, controller: controller, provider: provider, browser: browser, token: token)
    }
    func testAssignmentFiltersCatalogueAndRejectsForgedSession() async throws {
        let f = try await fixture()
        let response = try await f.controller.perform(f.envelope(.list), agent: f.agent)
        XCTAssertEqual(response.browsers?.map(\.id), [f.browser])
        var request = f.envelope(.tabs); request.request.browserID = UUID()
        do { _ = try await f.controller.perform(request, agent: f.agent); XCTFail("Unassigned browser accepted") } catch {}
        request = f.envelope(.tabs); request.token = "forged"
        do { _ = try await f.controller.perform(request, agent: f.agent); XCTFail("Forged session accepted") } catch {}
        let calls = await f.provider.transfers.count; XCTAssertEqual(calls, 0)
        let skill = f.local(".agents/skills/browser/SKILL.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: skill.path))
        try f.controller.assign([], to: f.agent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: skill.path))
    }
    func testWebMCPUsesTheSameSessionAndAssignmentBoundary() async throws {
        let f = try await fixture()
        var request = f.envelope(.webMCPCall)
        request.request.toolID = "document:registration"; request.request.arguments = "{}"
        _ = try await f.controller.perform(request, agent: f.agent)
        request.request.browserID = UUID()
        do { _ = try await f.controller.perform(request, agent: f.agent); XCTFail("Unassigned WebMCP accepted") } catch {}
        request.request.browserID = f.browser; request.token = "forged"
        do { _ = try await f.controller.perform(request, agent: f.agent); XCTFail("Forged WebMCP session accepted") } catch {}
        request.token = f.token
        try f.controller.assign([], to: f.agent)
        do { _ = try await f.controller.perform(request, agent: f.agent); XCTFail("Revoked WebMCP call accepted") } catch {}
        request.request.operation = .webMCPList; request.request.toolID = nil; request.request.arguments = nil
        do { _ = try await f.controller.perform(request, agent: f.agent); XCTFail("Revoked WebMCP discovery accepted") } catch {}
    }
    func testTransfersUseBrokerStagingAndPreserveBinaryBytes() async throws {
        let f = try await fixture(), data = Data([0, 255, 128, 4, 10])
        try data.write(to: f.local("source.bin"))
        var request = f.envelope(.upload, path: "source.bin")
        let forged = UUID(); request.request.transferID = forged
        let response = try await f.controller.perform(request, agent: f.agent)
        XCTAssertEqual(response.byteCount, Int64(data.count))
        let uploads = await f.provider.uploads; XCTAssertEqual(uploads.first, data)
        let requests = await f.provider.transfers; XCTAssertNotEqual(requests.first?.transferID, forged)
        _ = try await f.controller.perform(f.envelope(.download, path: "result.bin"), agent: f.agent)
        XCTAssertEqual(try Data(contentsOf: f.local("result.bin")), BrowserTestProvider.bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.group.appendingPathComponent("file-transfers").path), [])
    }
    func testRevocationDuringTransferPreventsPublishing() async throws {
        let f = try await fixture(blocked: true)
        let task = Task { try await f.controller.perform(f.envelope(.download, path: "result.bin"), agent: f.agent) }
        let deadline = Date().addingTimeInterval(5)
        while await f.provider.transfers.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let count = await f.provider.transfers.count; XCTAssertEqual(count, 1)
        try f.controller.assign([], to: f.agent)
        await f.provider.release()
        do { _ = try await task.value; XCTFail("Revoked download published") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.local("result.bin").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.group.appendingPathComponent("file-transfers").path), [])
    }
    func testInvalidSizesAndWorkspaceEscapesNeverPublish() async throws {
        let f = try await fixture(wrongCount: true)
        do { _ = try await f.controller.perform(f.envelope(.download, path: "result.bin"), agent: f.agent); XCTFail("Wrong size published") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.local("result.bin").path))
        let outside = f.root.appendingPathComponent("outside"); try Data([42]).write(to: outside)
        try FileManager.default.createSymbolicLink(at: f.local("link"), withDestinationURL: outside)
        for path in ["../outside", outside.path, "link"] {
            do { _ = try await f.controller.perform(f.envelope(.upload, path: path), agent: f.agent); XCTFail("Unsafe path accepted") } catch {}
        }
        XCTAssertEqual(try Data(contentsOf: outside), Data([42]))
        let calls = await f.provider.transfers.count; XCTAssertEqual(calls, 1)
    }
    func testSettingsCheckpointRestoresBrowserAssignments() async throws {
        let f = try await fixture()
        let checkpoint = try AgentSettingsCheckpoint(repository: f.repository)
        try f.controller.assign([], to: f.agent)
        try checkpoint.restore(); try f.controller.reloadAssignments()
        XCTAssertEqual(f.controller.selectedIDs(for: f.agent), [f.browser])
    }
    func testPresentRequiresConversationMembershipAndStoresAnOwnedReference() async throws {
        let f = try await fixture()
        let conversation = try XCTUnwrap(f.repository.loadConversations().first(where: { $0.participantIDs.contains(f.agent.id) }))
        var request = f.envelope(.present)
        do { _ = try await f.controller.perform(request, agent: f.agent); XCTFail("Missing conversation accepted") } catch {}
        let outsider = try f.repository.createAgent(named: "Other")
        request.conversationID = outsider.conversation.id
        do { _ = try await f.controller.perform(request, agent: f.agent); XCTFail("Unrelated conversation accepted") } catch {}
        request.conversationID = conversation.id; request.message = "Open this page"
        let response = try await f.controller.perform(request, agent: f.agent)
        let attachment = try XCTUnwrap(f.repository.loadAttachments(conversationID: conversation.id).first(where: { $0.id == response.attachmentID }))
        XCTAssertEqual(attachment.browser?.agentID, f.agent.id)
        XCTAssertEqual(attachment.browser?.reference.browser.id, f.browser)
        XCTAssertEqual(attachment.browser?.reference.tabID, request.request.tabID)
        let file = f.repository.attachmentFileURL(attachment)
        let reference = try BrowserReference.decode(Data(contentsOf: file))
        XCTAssertEqual(reference, attachment.browser?.reference)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertNil(wire["agentID"])
        XCTAssertEqual(try f.repository.loadMessages(conversationID: conversation.id).last?.attachmentIDs, [attachment.id])
        try f.controller.assign([], to: f.agent)
        do { _ = try await f.controller.perform(request, agent: f.agent); XCTFail("Revoked presentation accepted") } catch {}
    }
}
private actor BrowserTestProvider {
    static let bytes = Data([0, 1, 127, 128, 255])
    let root: URL
    var blocked: Bool
    let wrongCount: Bool
    let browsers = [RemoteBrowser(id: UUID(), name: "Assigned"), RemoteBrowser(id: UUID(), name: "Private")]
    var gates: [CheckedContinuation<Void, Never>] = []
    private(set) var transfers: [BrowserRequest] = []
    private(set) var uploads: [Data] = []
    init(root: URL, blocked: Bool, wrongCount: Bool) { self.root = root; self.blocked = blocked; self.wrongCount = wrongCount }
    func release() { blocked = false; let pending = gates; gates = []; for gate in pending { gate.resume() } }
    func respond(_ request: BrowserRequest) async throws -> BrowserResponse {
        var response = BrowserResponse()
        if request.operation == .list { response.browsers = browsers; return response }
        if request.operation == .present {
            response.reference = .init(browser: browsers[0], tabID: request.tabID!, url: "https://example.com", title: "Example")
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
