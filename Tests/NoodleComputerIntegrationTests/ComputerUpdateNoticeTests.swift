import ComputerBridge
import Foundation
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class ComputerUpdateNoticeTests: XCTestCase {
    private func controller(provider: UpdateNoticeProvider) throws -> ComputerController {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return ComputerController(repository: repository, applicationLookup: { nil },
                                  connection: { try await provider.respond($0) })
    }

    func testDiscoveryShowsNoticeBeforeAnyTransferAndClearsAfterUpgrade() async throws {
        let provider = UpdateNoticeProvider()
        let controller = try controller(provider: provider)
        XCTAssertFalse(controller.needsFileTransferUpdate)
        await controller.refresh()
        XCTAssertTrue(controller.needsFileTransferUpdate)
        XCTAssertTrue(controller.available)
        XCTAssertNil(controller.failure)
        // The application-level notice must also work before creating a guest.
        XCTAssertTrue(controller.registry.computers.isEmpty)
        let operations = await provider.operations
        XCTAssertEqual(operations, [.list])

        await provider.set(capabilities: ComputerCapabilities())
        await controller.refresh()
        XCTAssertFalse(controller.needsFileTransferUpdate)
        XCTAssertTrue(controller.available)
        XCTAssertNil(controller.failure)
    }

    func testDisconnectReplacesStaleNoticeAndReconnectRestoresIt() async throws {
        let provider = UpdateNoticeProvider()
        let controller = try controller(provider: provider)
        await controller.refresh()
        XCTAssertTrue(controller.needsFileTransferUpdate)
        await provider.set(error: "Computer is unavailable.")
        await controller.refresh()
        XCTAssertFalse(controller.needsFileTransferUpdate)
        XCTAssertFalse(controller.available)
        XCTAssertEqual(controller.failure, "Computer is unavailable.")

        await provider.set(error: nil)
        await controller.refresh()
        XCTAssertTrue(controller.needsFileTransferUpdate)
        XCTAssertTrue(controller.available)
        XCTAssertNil(controller.failure)
    }

    func testIncompatibleOrMalformedDiscoveryUsesExistingFailureInsteadOfFeatureNotice() async throws {
        var newerProtocol = ComputerCapabilities()
        newerProtocol.minimumProtocol = 2; newerProtocol.maximumProtocol = 2
        var missingRequired = ComputerCapabilities()
        missingRequired.features.remove("agent-terminals-v1")
        for capabilities in [nil, newerProtocol, missingRequired] {
            let provider = UpdateNoticeProvider()
            let controller = try controller(provider: provider)
            await controller.refresh()
            XCTAssertTrue(controller.needsFileTransferUpdate)
            await provider.set(capabilities: capabilities)
            await controller.refresh()
            XCTAssertFalse(controller.needsFileTransferUpdate)
            XCTAssertFalse(controller.available)
            XCTAssertNotNil(controller.failure)
        }
        let provider = UpdateNoticeProvider()
        let controller = try controller(provider: provider)
        await controller.refresh()
        await provider.omitCatalogue()
        await controller.refresh()
        XCTAssertFalse(controller.needsFileTransferUpdate)
        XCTAssertFalse(controller.available)
        XCTAssertEqual(controller.failure, "Invalid provider catalogue.")
    }
}

private actor UpdateNoticeProvider {
    private var capabilities: ComputerCapabilities?
    private var error: String?
    private var includesCatalogue = true
    private(set) var operations: [ComputerOperation] = []

    init() {
        var older = ComputerCapabilities()
        older.features.remove("file-transfer-v1")
        capabilities = older
    }
    func set(capabilities: ComputerCapabilities?) { self.capabilities = capabilities }
    func set(error: String?) { self.error = error }
    func omitCatalogue() { includesCatalogue = false }
    func respond(_ request: ComputerRequest) throws -> ComputerResponse {
        operations.append(request.operation)
        if let error { throw ComputerBridgeError(error) }
        var response = ComputerResponse(computers: includesCatalogue ? [] : nil)
        response.capabilities = capabilities
        return response
    }
}
