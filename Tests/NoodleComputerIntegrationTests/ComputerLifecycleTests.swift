import ComputerBridge
import Foundation
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class ComputerLifecycleTests: XCTestCase {
    private func fixture() async throws -> ComputerLifecycleFixture {
        let f = try ComputerLifecycleFixture(); addTeardownBlock { @MainActor in f.cleanUp() }
        try await f.prepare(); return f
    }

    func testAssignmentRevokedDuringHandshakeNeverDispatchesTerminalWrite() async throws {
        let f = try await fixture()
        f.provider.blockedOperation = .list
        let sent = try f.send(f.request(.terminalWrite))
        try await f.wait { f.provider.blocked != nil }
        try f.controller.assign([], to: f.a)
        f.provider.blocked?.finish(.success(f.provider.response(.list)))
        let response = try await f.response(sent)
        XCTAssertNotNil(response.error)
        XCTAssertEqual(f.provider.count(.terminalWrite), 0)
    }

    func testRevokedReadResponseDoesNotExposeTerminalData() async throws {
        let f = try await fixture()
        f.provider.blockedOperation = .terminalRead
        let sent = try f.send(f.request(.terminalRead))
        try await f.wait { f.provider.blocked != nil }
        try f.controller.assign([], to: f.a)
        f.provider.blocked?.finish(.success(f.provider.response(.terminalRead)))
        let response = try await f.response(sent)
        XCTAssertNotNil(response.error); XCTAssertNil(response.data)
        XCTAssertFalse(f.controller.registry.permits(f.card.computer.id, agent: f.card.agentID))
    }

    func testTransfersRevokedDuringDispatchHandshakeNeverReachProvider() async throws {
        for operation in [ComputerOperation.fileUpload, .fileDownload] {
            let f = try await fixture()
            let workspace = f.repository.directory(for: f.a)
            try Data([42]).write(to: workspace.appendingPathComponent("source.bin"))
            // The provider checks capabilities before staging, then performs a second handshake
            // and asks Noodle again immediately before sending the actual command.
            f.provider.blockedListNumber = f.provider.count(.list) + 2
            var request = f.request(operation); request.path = "/workspace/fixture.bin"; request.terminalID = nil
            let sent = try f.send(request, localPath: operation == .fileUpload ? "source.bin" : "result.bin")
            try await f.wait { f.provider.blocked != nil }
            try f.controller.assign([], to: f.a)
            f.provider.blocked?.finish(.success(f.provider.response(.list)))
            let response = try await f.response(sent)
            XCTAssertTrue(response.error?.contains("no longer assigned") == true, "\(operation): \(response.error ?? "success")")
            XCTAssertEqual(f.provider.count(operation), 0, "Revoked \(operation) was dispatched")
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("result.bin").path))
            let staging = f.root.appendingPathComponent("provider/file-transfers")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
        }
    }

    func testCatalogueIsWithheldWhenTheLastAssignmentIsRemovedWhileItLoads() async throws {
        let f = try await fixture()
        f.provider.blockedOperation = .list
        let sent = try f.send(.init(.list))
        try await f.wait { f.provider.blocked != nil }
        try f.controller.assign([], to: f.a)
        f.provider.blocked?.finish(.success(f.provider.response(.list)))
        let response = try await f.response(sent)
        XCTAssertNotNil(response.error)
        XCTAssertNil(response.computers)
    }

    func testUncertainTerminalWriteIsNotRetried() async throws {
        let f = try await fixture()
        f.provider.errorOperation = .terminalWrite
        let sent = try f.send(f.request(.terminalWrite))
        let response = try await f.response(sent)
        XCTAssertTrue(response.error?.contains("after dispatch") == true)
        let next = try f.send(f.request(.terminalRead)); _ = try await f.response(next)
        XCTAssertEqual(f.provider.count(.terminalWrite), 1)
        XCTAssertEqual(f.provider.count(.terminalRead), 1)
    }

    func testFailedAssignmentWritePreservesRegistryAndExistingAccess() async throws {
        let f = try await fixture(), path = f.root.appendingPathComponent("computers.json")
        let before = try Data(contentsOf: path)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        XCTAssertThrowsError(try f.controller.assign([], to: f.a))
        XCTAssertEqual(f.controller.selectedIDs(for: f.a), [f.provider.computer.id])
        XCTAssertTrue(f.controller.registry.permits(f.card.computer.id, agent: f.card.agentID))
        XCTAssertEqual(f.provider.count(.revoke), 0)
        try FileManager.default.removeItem(at: path); try before.write(to: path)
    }

    func testWorkspaceSyncFailureDoesNotSkipRevokedTerminalCleanup() async throws {
        let f = try await fixture()
        let instructions = f.repository.directory(for: f.a).appendingPathComponent("AGENTS.md")
        try FileManager.default.removeItem(at: instructions)
        try FileManager.default.createDirectory(at: instructions, withIntermediateDirectories: false)
        XCTAssertThrowsError(try f.controller.assign([], to: f.a))
        XCTAssertFalse(f.controller.registry.permits(f.card.computer.id, agent: f.card.agentID))
        try await f.wait { f.provider.count(.revoke) == 1 }
        XCTAssertEqual(try ComputerAssignments.load(root: f.root).assigned(to: f.a.id), [])
    }

    func testSupersededRefreshCannotReplaceNewerCatalogueOrFailureState() async throws {
        for fails in [false, true] {
            let f = try await fixture()
            f.provider.blockedOperation = .list
            let old = Task { await f.controller.refresh() }
            try await f.wait { f.provider.blocked != nil }
            let current = RemoteComputer(id: UUID(), name: "New provider", kind: "Shell", state: "Running", symbol: "terminal")
            f.provider.catalogue = [current]
            await f.controller.refresh()
            var response = ComputerResponse(computers: [f.provider.computer]); response.capabilities = ComputerCapabilities()
            f.provider.blocked?.finish(fails ? .failure(ComputerBridgeError("Old failure")) : .success(response))
            await old.value
            XCTAssertEqual(f.controller.registry.computers.map(\.id), [current.id])
            XCTAssertTrue(f.controller.available); XCTAssertNil(f.controller.failure)
        }
    }

    func testDuplicateProviderCatalogueDoesNotOverwriteSavedAssignments() async throws {
        let f = try await fixture(), before = try Data(contentsOf: f.root.appendingPathComponent("computers.json"))
        f.provider.catalogue = [f.provider.computer, f.provider.computer]
        await f.controller.refresh()
        XCTAssertFalse(f.controller.available)
        XCTAssertEqual(f.controller.failure, "Invalid provider catalogue.")
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("computers.json")), before)
    }

    func testAgentIdentityAndCatalogueFilteringAreBrokerOwned() async throws {
        let f = try await fixture()
        var request = f.request(.terminalRead); request.agentID = f.b.id
        let sent = try f.send(request); let response = try await f.response(sent)
        XCTAssertNil(response.error)
        XCTAssertEqual(f.provider.requests.last { $0.operation == .terminalRead }?.agentID, f.a.id)
        // A bot with no assigned computer has no computer tools at all.
        let list = try f.send(.init(.list), agent: f.b)
        let catalogue = try await f.response(list)
        XCTAssertTrue(catalogue.error?.contains("not assigned") == true, catalogue.error ?? "success")
        XCTAssertNil(catalogue.computers)
    }
}
