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

    func testPreviewRevokedDuringHandshakeNeverDispatchesTerminalWrite() async throws {
        let f = try await fixture()
        f.provider.blockedOperation = .list
        let task = Task { try await f.controller.previewCall(f.request(.terminalWrite), card: f.card) }
        try await f.wait { f.provider.blocked != nil }
        try f.controller.assign([], to: f.a)
        f.provider.blocked?.finish(.success(f.provider.response(.list)))
        do { _ = try await task.value; XCTFail("Revoked preview succeeded") } catch {}
        XCTAssertEqual(f.provider.count(.terminalWrite), 0)
    }

    func testAgentRemovedDuringHandshakeNeverDispatchesTerminalWrite() async throws {
        let f = try await fixture()
        f.provider.blockedOperation = .list
        let sent = try f.send(f.request(.terminalWrite))
        try await f.wait { f.provider.blocked != nil }
        f.controller.start(agents: [f.b], monitoring: false)
        f.provider.blocked?.finish(.success(f.provider.response(.list)))
        let response = try await f.response(sent)
        XCTAssertNotNil(response.error)
        XCTAssertNil(response.data)
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
        XCTAssertFalse(f.controller.permits(f.card))
    }

    func testUncertainTerminalWriteIsNotRetriedOrReplayedByAnotherScan() async throws {
        let f = try await fixture()
        f.provider.errorOperation = .terminalWrite
        let sent = try f.send(f.request(.terminalWrite))
        let response = try await f.response(sent)
        XCTAssertTrue(response.error?.contains("after dispatch") == true)
        f.controller.scan()
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
        XCTAssertTrue(f.controller.permits(f.card))
        XCTAssertEqual(f.provider.count(.revoke), 0)
        try FileManager.default.removeItem(at: path); try before.write(to: path)
    }

    func testWorkspaceSyncFailureDoesNotSkipRevokedTerminalCleanup() async throws {
        let f = try await fixture()
        let instructions = f.repository.directory(for: f.a).appendingPathComponent("AGENTS.md")
        try FileManager.default.removeItem(at: instructions)
        try FileManager.default.createDirectory(at: instructions, withIntermediateDirectories: false)
        XCTAssertThrowsError(try f.controller.assign([], to: f.a))
        XCTAssertFalse(f.controller.permits(f.card))
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

    func testStaleOrForgedPreviewCardCannotReachProvider() async throws {
        let f = try await fixture(), before = f.provider.requests.count
        for operation in [ComputerOperation.terminalRead, .terminalWrite, .display, .revoke] {
            var request = f.request(operation); request.agentID = f.b.id
            do { _ = try await f.controller.previewCall(request, card: f.card); XCTFail("Forged preview accepted") } catch {}
        }
        XCTAssertEqual(f.provider.requests.count, before)
        f.controller.start(agents: [f.b], monitoring: false)
        XCTAssertFalse(f.controller.permits(f.card))
    }

    func testAgentIdentityAndCatalogueFilteringAreBrokerOwned() async throws {
        let f = try await fixture()
        var request = f.request(.terminalRead); request.agentID = f.b.id
        let sent = try f.send(request); let response = try await f.response(sent)
        XCTAssertNil(response.error)
        XCTAssertEqual(f.provider.requests.last { $0.operation == .terminalRead }?.agentID, f.a.id)
        let list = try f.send(.init(.list), agent: f.b)
        let catalogue = try await f.response(list)
        XCTAssertEqual(catalogue.computers?.count, 0)
        XCTAssertNotNil(catalogue.capabilities)
    }

    func testFailedBridgeSessionWriteCanBeRetriedOnNextStart() async throws {
        let f = try await fixture()
        f.controller.start(agents: [], monitoring: false)
        let bridge = try ComputerAgentSkill.bridge(workspace: f.repository.directory(for: f.a))
        let session = bridge.appendingPathComponent("session.json")
        try FileManager.default.removeItem(at: session)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false)
        f.controller.start(agents: [f.a], monitoring: false)
        XCTAssertNotNil(f.controller.failure)
        try FileManager.default.removeItem(at: session)
        f.controller.start(agents: [f.a], monitoring: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.path))
        let sent = try f.send(f.request(.terminalRead)); let response = try await f.response(sent)
        XCTAssertNil(response.error)
    }
}
