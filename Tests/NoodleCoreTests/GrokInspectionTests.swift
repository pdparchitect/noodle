import XCTest
@testable import NoodleCore

final class GrokInspectionTests: XCTestCase {
    private let initialization: [String: Any] = [
        "protocolVersion": 1, "privateAccount": "fixture-secret",
        "_meta": ["modelState": ["currentModelId": "fixture/second", "availableModels": [
            ["modelId": "fixture/first", "name": "First"],
            ["modelId": "fixture/second", "name": "Second"],
            ["modelId": "fixture/first"], ["modelId": "--unsafe"]
        ]]]
    ]

    func testSuccessfulInspectionUsesOnlyReadOnlyHandshakeAndSanitizesResults() throws {
        let fixture = try peer(auth: ["result": ["account": "fixture-secret"]])
        let result = try inspect(fixture)
        XCTAssertTrue(result.authenticated)
        XCTAssertEqual(result.executablePath, "/reported/grok")
        XCTAssertEqual(result.models.map(\.id), ["fixture/first", "fixture/second"])
        XCTAssertEqual(result.models.map(\.isDefault), [false, true])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("fixture-secret"))
        XCTAssertEqual(try fixture.arguments, ["agent", "--no-leader", "stdio"])
        let requests = try fixture.requests
        XCTAssertEqual(requests.compactMap { $0["method"] as? String }, ["initialize", "authenticate"])
        XCTAssertEqual(requests.compactMap { $0["id"] as? Int }, [1, 2])
        XCTAssertTrue(requests.allSatisfy { $0["jsonrpc"] as? String == "2.0" })
        let params = try XCTUnwrap(requests.first?["params"] as? [String: Any])
        XCTAssertEqual(params["protocolVersion"] as? Int, 1)
        let capabilities = try XCTUnwrap(params["clientCapabilities"] as? [String: Any])
        XCTAssertEqual(capabilities["terminal"] as? Bool, false)
        XCTAssertEqual(capabilities["fs"] as? [String: Bool], ["readTextFile": false, "writeTextFile": false])
        XCTAssertEqual(requests.last?["params"] as? [String: String], ["methodId": "cached_token"])
        try fixture.assertStopped()
    }

    func testAuthenticationRejectionDoesNotHideAvailableModelsOrEchoPrivateErrors() throws {
        let fixture = try peer(auth: ["error": ["code": -32000, "message": "fixture-secret"]])
        let result = try inspect(fixture)
        XCTAssertFalse(result.authenticated)
        XCTAssertEqual(result.models.count, 2)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("fixture-secret"))
        try fixture.assertStopped()
    }

    func testUnsupportedInitializationStopsBeforeAuthentication() throws {
        for result in [[String: Any](), ["protocolVersion": 2]] {
            let fixture = try InspectionProcessFixture(script: "read_request\n" + reply(1, ["result": result]))
            assertInspectionFailure(fixture)
            XCTAssertEqual(try fixture.requests.compactMap { $0["method"] as? String }, ["initialize"])
            try fixture.assertStopped()
        }
    }

    func testInvalidCatalogueCannotBecomeSuccessfulEmptyDiscovery() throws {
        var invalid = initialization
        invalid["_meta"] = [:]
        let fixture = try peer(initialization: invalid)
        assertInspectionFailure(fixture)
        try fixture.assertStopped()
    }

    func testUnsupportedResponseEnvelopeIsRejected() throws {
        for version in [nil, "1.0"] as [String?] {
            var response: [String: Any] = ["id": 1, "result": initialization]
            response["jsonrpc"] = version
            let fixture = try InspectionProcessFixture(script: "read_request\n" + InspectionProcessFixture.emit(response))
            assertInspectionFailure(fixture)
            try fixture.assertStopped()
        }
    }

    func testPublicInspectionRejectsUnsignedInstallationWithoutLaunchingIt() throws {
        let fixture = try InspectionProcessFixture(script: "exit 1")
        let installed = fixture.home.appendingPathComponent(".grok/bin/grok")
        try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.executable, to: installed)
        XCTAssertThrowsError(try GrokInspection.inspect(home: fixture.home, environment: fixture.environment)) {
            XCTAssertTrue($0.localizedDescription.contains("signature"))
        }
        XCTAssertFalse(fixture.wasLaunched)
    }

    func testMalformedAuthenticationRepliesCannotReportAuthenticated() throws {
        for payload: [String: Any] in [[:], ["result": []], ["error": "fixture-secret"],
                                       ["result": [:], "error": ["code": -32000, "message": "fixture-secret"]]] {
            let fixture = try peer(auth: payload)
            assertInspectionFailure(fixture)
            try fixture.assertStopped()
        }
    }

    func testUnsolicitedFutureResponseCannotOverrideActualAuthenticationFailure() throws {
        let future = try reply(2, ["result": [:]])
        let fixture = try peer(auth: ["error": ["code": -32000, "message": "denied"]], beforeInitialization: future)
        XCTAssertFalse(try inspect(fixture).authenticated)
        try fixture.assertStopped()
    }

    func testNoiseNotificationsAndFragmentedResponsesDoNotBreakHandshake() throws {
        let response = try reply(1, ["result": initialization])
        let fixture = try InspectionProcessFixture(script: """
        read_request
        printf '%s\\n' 'not JSON' '[]' '{"jsonrpc":"2.0","method":"notice","params":{}}' '{"jsonrpc":"2.0","id":99,"result":{}}'
        \(response)
        read_request
        printf '%s' '{"jsonrpc":"2.0","id":2,'
        printf '%s\\n' '"result":{}}'
        """)
        XCTAssertTrue(try inspect(fixture).authenticated)
        XCTAssertEqual(try fixture.requests.count, 2)
        try fixture.assertStopped()
    }

    func testMalformedOutputTimesOutAndKillsAnUncooperativePeer() throws {
        let fixture = try InspectionProcessFixture(script: "read_request\nprintf '%s\\n' 'invalid JSON'", ignoreTermination: true)
        let started = Date()
        assertInspectionFailure(fixture, timeout: 2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(try fixture.requests.count, 1)
        try fixture.assertStopped()
    }

    func testClosedOutputFailsPromptlyEvenIfProcessRemainsAlive() throws {
        let fixture = try InspectionProcessFixture(script: "read_request\nexec 1>&-", ignoreTermination: true)
        let started = Date()
        assertInspectionFailure(fixture, timeout: 4)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "EOF must wake the waiter without waiting for its deadline")
        try fixture.assertStopped()
    }

    func testCrashFailsAndValidFinalResponseSurvivesImmediateExit() throws {
        let crashed = try InspectionProcessFixture(script: "read_request\nprintf '%s' 'fixture-secret' >&2\nexit 17")
        assertInspectionFailure(crashed)
        try crashed.assertStopped()
        for _ in 0..<5 {
            let fixture = try peer(afterAuthentication: "exit 0")
            XCTAssertTrue(try inspect(fixture).authenticated)
            try fixture.assertStopped()
        }
    }

    func testMissingInstallationAndUnlaunchableExecutable() throws {
        let fixture = try InspectionProcessFixture(script: "exit 1")
        let missing = try GrokInspection.inspect(home: fixture.home, environment: [:])
        XCTAssertNil(missing.executablePath)
        XCTAssertFalse(missing.authenticated)
        XCTAssertTrue(missing.models.isEmpty)
        XCTAssertThrowsError(try GrokInspection.inspect(executable: fixture.home.appendingPathComponent("missing"),
            installationPath: "/missing", environment: fixture.environment))
    }

    private func inspect(_ fixture: InspectionProcessFixture, timeout: TimeInterval = 3) throws -> GrokInspectionResult {
        try GrokInspection.inspect(executable: fixture.executable, installationPath: "/reported/grok", environment: fixture.environment,
                                   requestTimeout: timeout, terminationGrace: 0.2)
    }
    private func assertInspectionFailure(_ fixture: InspectionProcessFixture, timeout: TimeInterval = 3,
                                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try inspect(fixture, timeout: timeout), file: file, line: line) {
            XCTAssertTrue($0 is HarnessSetupError, file: file, line: line)
            XCTAssertFalse($0.localizedDescription.contains("fixture-secret"), file: file, line: line)
        }
    }
    private func peer(initialization: [String: Any]? = nil, auth: [String: Any] = ["result": [:]],
                      beforeInitialization: String = "", afterAuthentication: String = "") throws -> InspectionProcessFixture {
        try InspectionProcessFixture(script: """
        read_request
        \(beforeInitialization)
        \(reply(1, ["result": initialization ?? self.initialization]))
        read_request
        \(reply(2, auth))
        \(afterAuthentication)
        """)
    }
    private func reply(_ id: Int, _ payload: [String: Any]) throws -> String {
        try InspectionProcessFixture.emit(payload.merging(["jsonrpc": "2.0", "id": id]) { _, new in new })
    }
}
