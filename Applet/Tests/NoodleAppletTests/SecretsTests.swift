import AppletCore
import XCTest
@testable import NoodleApplet

private final class MemorySecrets: AppletSecretStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: [String: String]] = [:]
    func load(_ account: String) throws -> [String: String] { lock.withLock { items[account] ?? [:] } }
    func save(_ values: [String: String], account: String) throws { lock.withLock { items[account] = values.isEmpty ? nil : values } }
    func accounts() throws -> [String] { lock.withLock { Array(items.keys) } }
}

@MainActor final class SecretsTests: XCTestCase {
    func testSecretsAreSeparateForEachNoodletAndScope() throws {
        let secrets = AppletSecrets(storage: MemorySecrets())
        XCTAssertTrue(try secrets.perform("set", name: "token", value: "one", account: "a.user") as? Bool == true)
        XCTAssertEqual(try secrets.perform("get", name: "token", value: nil, account: "a.user") as? String, "one")
        XCTAssertTrue(try secrets.perform("get", name: "token", value: nil, account: "b.user") is NSNull)
        XCTAssertTrue(try secrets.perform("get", name: "token", value: nil, account: "a.test") is NSNull)
        XCTAssertEqual(try secrets.perform("names", name: nil, value: nil, account: "a.user") as? [String], ["token"])
        XCTAssertEqual(secrets.names(), ["a.user": ["token"]])
        _ = try secrets.perform("delete", name: "token", value: nil, account: "a.user")
        XCTAssertTrue(secrets.names().isEmpty)
    }

    func testLimitsAreEnforced() throws {
        let secrets = AppletSecrets(storage: MemorySecrets())
        XCTAssertThrowsError(try secrets.perform("set", name: "", value: "x", account: "a.user"))
        XCTAssertThrowsError(try secrets.perform("set", name: "big", value: String(repeating: "x", count: 16385), account: "a.user"))
        for index in 0..<64 { _ = try secrets.perform("set", name: "n\(index)", value: "v", account: "a.user") }
        XCTAssertThrowsError(try secrets.perform("set", name: "one-more", value: "v", account: "a.user"))
        XCTAssertNoThrow(try secrets.perform("set", name: "n0", value: "replaced", account: "a.user"))
    }

    func testHTMLBridgeUsesTheNoodletsOwnAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try NoodletPackage.install([
            "noodlet.json": Data(#"{"version":1,"title":"Keys","runtime":"html","entry":"index.html"}"#.utf8),
            "index.html": Data("<title>Keys</title>".utf8),
        ], to: root.appendingPathComponent("Keys.noodlet"))
        let dataRoot = root.appendingPathComponent("User")
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        let secrets = AppletSecrets(storage: MemorySecrets())
        let runner = WebRunner(
            package: package, dataRoot: dataRoot, log: AppletLog(url: root.appendingPathComponent("log.txt")),
            size: CGSize(width: 320, height: 240), storeID: UUID(), rememberFrame: false, secrets: secrets)
        let (saved, failure) = await runner.handleBridge(operation: "secret", body: ["action": "set", "name": "key", "value": "v", "account": "other.user"])
        XCTAssertNil(failure)
        XCTAssertEqual(saved as? Bool, true)
        let (value, _) = await runner.handleBridge(operation: "secret", body: ["action": "get", "name": "key"])
        XCTAssertEqual(value as? String, "v")
        XCTAssertEqual(secrets.names(), ["\(package.key).user": ["key"]], "A page cannot choose another noodlet's account")
    }
}
