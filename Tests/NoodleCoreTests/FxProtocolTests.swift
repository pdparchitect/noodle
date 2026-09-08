import XCTest
@testable import NoodleCore

final class FxProtocolTests: XCTestCase {
    func testHeldReviewsAreNotSuccessfulToolRuns() {
        let content: [[String: Any]] = [["content": ["type": "text", "text": #"{"error":{"type":"tool_review_held","held":true}}"#]]]
        XCTAssertTrue(FxProtocol.reviewWasHeld(["sessionUpdate": "tool_call_update", "status": "failed", "content": content]))
        XCTAssertFalse(FxProtocol.reviewWasHeld(["sessionUpdate": "tool_call_update", "status": "completed", "content": content]))
        XCTAssertFalse(FxProtocol.reviewWasHeld([:]))
    }
    func testCatalogueUsesActualIDsAndDeduplicates() throws {
        let data = Data(#"{"kind":"models","ids":["openai/gpt-5.2","anthropic/claude-sonnet","openai/gpt-5.2","--bad","bad\nmodel"]}"#.utf8)
        let models = try FxProtocol.models(from: data, defaultModel: "openai/gpt-5.2")
        XCTAssertEqual(models.map(\.id), ["openai/gpt-5.2", "anthropic/claude-sonnet"])
        XCTAssertTrue(models[0].isDefault)
        XCTAssertTrue(models[0].supportedEfforts.isEmpty)
        XCTAssertThrowsError(try FxProtocol.models(from: Data("{}".utf8), defaultModel: nil))
    }
    func testPermissionsRequireCurrentSessionAndOnlyGrantOnce() {
        let params: [String: Any] = ["sessionId": "one", "options": [
            ["optionId": "always", "kind": "allow_always"], ["optionId": "once", "kind": "allow_once"]]]
        let granted = FxProtocol.permissionResponse(params: params, sessionID: "one", extendedAccess: true)
        XCTAssertEqual((granted["outcome"] as? [String: String])?["optionId"], "once")
        for (id, extended) in [("one", false), ("other", true)] {
            let denied = FxProtocol.permissionResponse(params: params, sessionID: id, extendedAccess: extended)
            XCTAssertEqual((denied["outcome"] as? [String: String])?["outcome"], "cancelled")
        }
        XCTAssertEqual((FxProtocol.permissionResponse(params: ["sessionId": "one"], sessionID: "one", extendedAccess: true)["outcome"] as? [String: String])?["outcome"], "cancelled")
    }
    func testLoginChallengeAllowsOnlyVercelHTTPS() {
        XCTAssertNil(FxProtocol.loginChallenge("Open https://vercel.com/verify\nCode: PARTIAL"))
        XCTAssertNotNil(FxProtocol.loginChallenge("Open https://vercel.com/verify?code=one\nCode: ABC-123\n"))
        for url in ["http://vercel.com/verify", "https://vercel.com.evil.test/verify", "https://user@vercel.com/verify", "https://vercel.com:444/verify"] {
            XCTAssertNil(FxProtocol.loginChallenge("Open \(url)\nCode: ABC\n"))
        }
    }
    func testOfficialInstallDiscoveryAndUnsignedRejection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent(".local/bin/fx")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a signed executable".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let found = HarnessDiscovery(homeDirectory: root, executableSearchDirectories: [], environment: [:]).discover(.fx)
        XCTAssertEqual(found.executablePath, executable.path)
        XCTAssertThrowsError(try FxExecutableTrust.executable(at: executable.path, home: root))
        XCTAssertThrowsError(try FxExecutableTrust.executable(at: "/bin/sh", home: root))
    }
}
