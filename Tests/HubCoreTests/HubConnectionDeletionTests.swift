import Foundation
import HubCore
import NoodleCore
import XCTest
@testable import NoodleMCP

/// A removed connection's sign-in leaves the Hub's Keychain even when the first attempt fails.
@MainActor final class HubConnectionDeletionTests: XCTestCase {
    func testASignInThatFailsToDeleteIsDeletedWhenTheHubNextStarts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-deletions-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let access = HubAccess(url: root.appendingPathComponent("access.json"))
        let ada = try access.addUser(named: "Ada")
        let keychain = RefusingHubCredentials()
        let service = MCPService(credentials: keychain, oauth: MCPOAuth(), httpConfiguration: { .ephemeral })
        let first = HubConnections(root: root, access: access, service: service)
        let notes = try first.add(try MCPConnectionRecord(name: "Notes", endpoint: URL(string: "https://example.com/mcp")!), for: ada)
        keychain.refusing = true
        try first.remove(notes.id, for: ada)
        XCTAssertTrue(first.connections(for: ada).isEmpty, "Access must be revoked before the sign-in is deleted")
        for _ in 0..<200 where keychain.attempts == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(keychain.removed, [])

        keychain.refusing = false
        _ = HubConnections(root: root, access: access, service: service)
        for _ in 0..<200 where keychain.removed.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(keychain.removed, [notes.id])
    }
}

/// A Keychain that refuses deletions until told otherwise, and records the ones it made.
private final class RefusingHubCredentials: MCPCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var refusal = false, tries = 0, deleted: [UUID] = []
    var refusing: Bool { get { lock.withLock { refusal } } set { lock.withLock { refusal = newValue } } }
    var attempts: Int { lock.withLock { tries } }
    var removed: [UUID] { lock.withLock { deleted } }
    func load(_ id: UUID) throws -> MCPCredentials? { nil }
    func save(_ credentials: MCPCredentials, id: UUID) { XCTFail("These tests must never authorize an account") }
    func remove(_ id: UUID) throws {
        try lock.withLock {
            tries += 1
            if refusal { throw MCPServiceError.keychain(-25308) }
            deleted.append(id)
        }
    }
}
