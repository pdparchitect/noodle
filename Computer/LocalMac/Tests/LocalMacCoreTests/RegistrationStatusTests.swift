import XCTest
@testable import LocalMacCore

final class RegistrationStatusTests: XCTestCase {
    private func executable(_ body: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("query")
        try ("#!/bin/sh\n[ \"$#\" = 1 ] && [ \"$1\" = --registration-status ] || exit 2\n" + body + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    func testReportsOnlyExplicitRegistrarStates() async throws {
        for status: LocalMacRegistrationStatus in [.notRegistered, .requiresApproval, .enabled, .helperMissing] {
            let result = await LocalMacRegistrationProbe.read(executable: try executable("printf '\(status.rawValue)\\n'"))
            XCTAssertEqual(result, status)
        }
        for body in ["printf 'notRegistered\\n'; exit 1", "printf 'invalid\\n'", "exit 0"] {
            let result = await LocalMacRegistrationProbe.read(executable: try executable(body))
            XCTAssertEqual(result, .unknown)
            XCTAssertFalse(result.needsSetup)
        }
    }
    func testMissingSlowAndCancelledQueriesDoNotClaimPermissionIsMissing() async throws {
        let missing = await LocalMacRegistrationProbe.read(executable: URL(fileURLWithPath: "/no-such-setup-helper"))
        XCTAssertEqual(missing, .unknown)
        let slow = try executable("exec /bin/sleep 30")
        let result = await LocalMacRegistrationProbe.read(executable: slow, timeout: 0.05)
        XCTAssertEqual(result, .unknown)
        let task = Task { await LocalMacRegistrationProbe.read(executable: slow) }
        task.cancel()
        let cancelled = await task.value
        XCTAssertEqual(cancelled, .unknown)
    }
}
