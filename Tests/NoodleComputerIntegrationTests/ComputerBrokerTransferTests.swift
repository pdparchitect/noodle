import ComputerBridge
import Foundation
import NoodleCore
import XCTest
@testable import Noodle

/// Real broker, workspace IPC, assignments and file I/O, with only the signed
/// provider connection replaced. Gates make revocation/concurrency deterministic.
@MainActor final class ComputerBrokerTransferTests: XCTestCase {
    private func fixture(blocked: Bool = false, failure: String? = nil,
                         count: Int64? = nil, supportsTransfers: Bool = true) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let group = root.appendingPathComponent("group")
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("library"))
        try repository.prepare()
        let a = try repository.createAgent(named: "Transfer A").agent
        let b = try repository.createAgent(named: "Transfer B").agent
        let provider = TransferProvider(root: group, blocked: blocked, failure: failure,
                                        count: count, supportsTransfers: supportsTransfers)
        let controller = ComputerController(repository: repository, socket: group.appendingPathComponent("fixture.sock"),
            applicationLookup: { nil }, connection: { try await provider.respond($0) })
        await controller.refresh()
        let computer = try XCTUnwrap(controller.registry.computers.first)
        try controller.assign([computer.id], to: a)
        try controller.assign([computer.id], to: b)
        controller.start(agents: [a, b])
        addTeardownBlock {
            await provider.release()
            await MainActor.run { controller.start(agents: []) }
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(root: root, group: group, repository: repository, controller: controller,
                       provider: provider, computer: computer.id, a: a, b: b)
    }

    func testRevocationWhileProviderIsTransferringNeverPublishesDownload() async throws {
        let f = try await fixture(blocked: true)
        let sent = try f.send(agent: f.a)
        try await f.waitForTransfers(1)
        try f.controller.assign([], to: f.a)
        await f.provider.release()
        let response = try await sent.response()
        XCTAssertTrue(response.error?.contains("revoked") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.local(f.a, "result.bin").path))
        try f.assertNoStaging()
    }

    func testProviderDisconnectAfterPartialDownloadCleansUpWithoutRetry() async throws {
        let f = try await fixture(failure: "Computer disconnected or timed out.")
        let sent = try f.send(agent: f.a)
        let response = try await sent.response()
        XCTAssertTrue(response.error?.contains("disconnected") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.local(f.a, "result.bin").path))
        try f.assertNoStaging()
        // Leave the same request on disk and submit another operation. This
        // ensures subsequent scans occur without replaying the failed mutation.
        let next = try f.send(agent: f.a, operation: .terminalOpen, localPath: nil)
        let opened = try await next.response()
        XCTAssertNotNil(opened.terminalID)
        let requests = await f.provider.transfers
        XCTAssertEqual(requests.count, 1)
    }

    func testUncertainUploadIsReportedOnceAndStagingIsRemoved() async throws {
        let f = try await fixture(failure: "Connection lost after accepting upload.")
        let bytes = Data([0, 255, 1, 128])
        try bytes.write(to: f.local(f.a, "source.bin"))
        let sent = try f.send(agent: f.a, operation: .fileUpload, localPath: "source.bin")
        let response = try await sent.response()
        XCTAssertTrue(response.error?.contains("Connection lost") == true)
        let transfers = await f.provider.transfers
        let uploaded = await f.provider.uploads
        XCTAssertEqual(transfers.count, 1)
        XCTAssertEqual(uploaded[f.a.id], bytes)
        XCTAssertEqual(try Data(contentsOf: f.local(f.a, "source.bin")), bytes)
        try f.assertNoStaging()
    }

    func testConcurrentAgentsUseDistinctStagingAndBrokerOwnedIdentity() async throws {
        let f = try await fixture(blocked: true)
        let bytes = Data([255, 0, 64, 128])
        try bytes.write(to: f.local(f.a, "source.bin"))
        let forged = UUID()
        let upload = try f.send(agent: f.a, operation: .fileUpload, localPath: "source.bin") {
            $0.request.agentID = f.b.id; $0.request.transferID = forged
        }
        let download = try f.send(agent: f.b) {
            $0.request.agentID = f.a.id; $0.request.transferID = forged
        }
        try await f.waitForTransfers(2)
        let transfers = await f.provider.transfers
        XCTAssertEqual(Set(transfers.compactMap(\.transferID)).count, 2)
        XCTAssertFalse(transfers.contains { $0.transferID == forged })
        XCTAssertEqual(transfers.first { $0.operation == .fileUpload }?.agentID, f.a.id)
        XCTAssertEqual(transfers.first { $0.operation == .fileDownload }?.agentID, f.b.id)
        await f.provider.release()
        let uploaded = try await upload.response(), downloaded = try await download.response()
        XCTAssertNil(uploaded.error); XCTAssertNil(downloaded.error)
        XCTAssertEqual(uploaded.byteCount, Int64(bytes.count))
        XCTAssertEqual(try Data(contentsOf: f.local(f.b, "result.bin")), TransferProvider.bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.local(f.a, "result.bin").path))
        try f.assertNoStaging()
    }

    func testOldProviderRejectsTransfersButKeepsTerminalOperationsWorking() async throws {
        let f = try await fixture(supportsTransfers: false)
        let sent = try f.send(agent: f.a, operation: .fileUpload, localPath: "missing.bin")
        let response = try await sent.response()
        XCTAssertEqual(response.error, "Update Noodle Computer to upload and download files.")
        let terminal = try f.send(agent: f.a, operation: .terminalOpen, localPath: nil)
        let opened = try await terminal.response()
        XCTAssertNotNil(opened.terminalID)
        let transfers = await f.provider.transfers
        XCTAssertTrue(transfers.isEmpty)
        try f.assertNoStaging()
    }

    func testIncorrectDownloadSizeNeverPublishesAndRemovesStaging() async throws {
        for count in [-1, ComputerTransferFiles.limit + 1, Int64(TransferProvider.bytes.count + 1)] {
            let f = try await fixture(count: count)
            let response = try await f.send(agent: f.a).response()
            XCTAssertNotNil(response.error)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.local(f.a, "result.bin").path))
            try f.assertNoStaging()
        }
    }

    func testBrokerRejectsForgedEnvelopesAndPathsWithoutTrustingCLIValidation() async throws {
        let f = try await fixture()
        let outside = f.root.appendingPathComponent("outside")
        try Data([42]).write(to: outside)
        try FileManager.default.createSymbolicLink(at: f.local(f.a, "link"), withDestinationURL: outside)
        let edits: [(inout ComputerAgentRequest) -> Void] = [
            { $0.token = "forged" },
            { $0.expiresAt = .distantPast },
            { $0.request.computerID = UUID() },
            { $0.localPath = nil },
            { $0.localPath = outside.path },
            { $0.localPath = "../outside" },
            { $0.localPath = "link" }
        ]
        for edit in edits {
            let sent = try f.send(agent: f.a, operation: .fileUpload, localPath: "source.bin", edit: edit)
            let response = try await sent.response()
            XCTAssertNotNil(response.error)
            try f.assertNoStaging()
        }
        XCTAssertEqual(try Data(contentsOf: outside), Data([42]))
        let transfers = await f.provider.transfers
        XCTAssertTrue(transfers.isEmpty)
    }
}

@MainActor private struct Fixture {
    let root: URL
    let group: URL
    let repository: WorkspaceRepository
    let controller: ComputerController
    let provider: TransferProvider
    let computer: UUID
    let a: AgentRecord
    let b: AgentRecord

    func local(_ agent: AgentRecord, _ path: String) -> URL { repository.directory(for: agent).appendingPathComponent(path) }

    func send(agent: AgentRecord, operation: ComputerOperation = .fileDownload, localPath: String? = "result.bin",
              edit: (inout ComputerAgentRequest) -> Void = { _ in }) throws -> SentRequest {
        let directory = try ComputerAgentSkill.bridge(workspace: repository.directory(for: agent))
        let session = try JSONDecoder().decode(MCPBridgeSession.self, from: Data(contentsOf: directory.appendingPathComponent("session.json")))
        var request = ComputerRequest(operation, computerID: computer)
        if operation.isFileTransfer { request.path = "/workspace/file.bin" }
        var envelope = ComputerAgentRequest(token: session.token, request: request)
        envelope.localPath = localPath
        edit(&envelope)
        let stem = directory.appendingPathComponent(envelope.id.uuidString.lowercased())
        try ComputerAgentFiles.write(envelope, to: stem.appendingPathExtension("request"))
        return SentRequest(url: stem.appendingPathExtension("response"))
    }

    func waitForTransfers(_ count: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await provider.transfers.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ComputerBridgeError("Fixture timed out waiting for broker transfers.")
    }

    func assertNoStaging(file: StaticString = #filePath, line: UInt = #line) throws {
        let directory = group.appendingPathComponent("file-transfers")
        if FileManager.default.fileExists(atPath: directory.path) {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [], file: file, line: line)
        }
        for agent in [a, b] {
            let files = try FileManager.default.contentsOfDirectory(atPath: repository.directory(for: agent).path)
            XCTAssertFalse(files.contains { $0.hasPrefix(".noodle-download-") }, file: file, line: line)
        }
    }
}

private struct SentRequest {
    let url: URL
    func response() async throws -> ComputerResponse {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return try JSONDecoder().decode(ComputerResponse.self, from: Data(contentsOf: url))
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ComputerBridgeError("Fixture timed out waiting for the broker response.")
    }
}

private actor TransferProvider {
    static let bytes = Data([0, 1, 127, 128, 255])
    private let root: URL
    private let failure: String?
    private let count: Int64?
    private let supportsTransfers: Bool
    private var blocked: Bool
    private var gates: [CheckedContinuation<Void, Never>] = []
    private let computer = RemoteComputer(id: UUID(), name: "Fixture", kind: "Shell", state: "Running", symbol: "terminal")
    private(set) var transfers: [ComputerRequest] = []
    private(set) var uploads: [UUID: Data] = [:]

    init(root: URL, blocked: Bool, failure: String?, count: Int64?, supportsTransfers: Bool) {
        self.root = root; self.blocked = blocked; self.failure = failure; self.count = count
        self.supportsTransfers = supportsTransfers
    }

    func release() {
        blocked = false
        let pending = gates; gates = []
        for gate in pending { gate.resume() }
    }

    func respond(_ request: ComputerRequest) async throws -> ComputerResponse {
        if request.operation == .list {
            var response = ComputerResponse(computers: [computer])
            var capabilities = ComputerCapabilities()
            if !supportsTransfers { capabilities.features.remove("file-transfer-v1") }
            response.capabilities = capabilities
            return response
        }
        guard request.operation.isFileTransfer else {
            return ComputerResponse(terminalID: request.operation == .terminalOpen ? UUID() : nil)
        }
        transfers.append(request)
        let id = try XCTUnwrap(request.transferID), agent = try XCTUnwrap(request.agentID)
        let staging = try ComputerTransferFiles.staging(root: root, id: id, create: false)
        var byteCount = Int64(Self.bytes.count)
        if request.operation == .fileUpload {
            let bytes = try Data(contentsOf: staging)
            uploads[agent] = bytes; byteCount = Int64(bytes.count)
        } else { try Self.bytes.write(to: staging) }
        if blocked { await withCheckedContinuation { gates.append($0) } }
        if let failure { throw ComputerBridgeError(failure) }
        var response = ComputerResponse()
        response.path = request.path; response.byteCount = count ?? byteCount
        return response
    }
}
