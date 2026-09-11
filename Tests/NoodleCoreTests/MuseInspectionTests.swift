import XCTest
@testable import NoodleCore

final class MuseInspectionTests: XCTestCase {
    private let initialization: [String: Any] = ["serverInfo": ["name": "muse"], "schema": ["version": 1], "sessionDurability": "ephemeral"]
    private let catalogue: [String: Any] = ["providerId": "meta", "privateAccount": "fixture-secret", "models": [
        ["providerId": "meta", "modelId": "fixture/first", "displayLabel": "First"],
        ["providerId": "meta", "modelId": "fixture/second", "isDefault": true],
        ["providerId": "meta", "modelId": "fixture/first"], ["providerId": "other", "modelId": "wrong"]
    ]]

    func testSuccessfulInspectionOnlyListsModelsWithoutLoginOrSessions() throws {
        let fixture = try peer()
        let result = try inspect(fixture)
        XCTAssertEqual(result.executablePath, "/reported/muse")
        XCTAssertEqual(result.authentication, .unauthenticated)
        XCTAssertEqual(result.models.map(\.id), ["fixture/first", "fixture/second"])
        XCTAssertEqual(result.models.map(\.isDefault), [false, true])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("fixture-secret"))
        XCTAssertEqual(try fixture.arguments, ["serve", "--no-session-log"])
        let requests = try fixture.requests
        XCTAssertEqual(requests.compactMap { $0["method"] as? String }, ["initialize", "initialized", "model/list"])
        XCTAssertTrue(requests.allSatisfy { $0["jsonrpc"] as? String == "2.0" })
        XCTAssertEqual(requests[0]["id"] as? Int, 1)
        XCTAssertNil(requests[1]["id"], "initialized is a notification")
        XCTAssertEqual(requests[2]["id"] as? Int, 2)
        XCTAssertEqual((requests[0]["params"] as? [String: Any])?["clientInfo"] as? [String: String], ["name": "noodle", "version": "1"])
        XCTAssertEqual((requests[2]["params"] as? [String: Any])?.count, 0)
        try fixture.assertStopped()
    }

    func testUnsupportedInitializationStopsBeforeModelRequest() throws {
        for result in [[String: Any](), ["schema": ["version": 2], "serverInfo": ["name": "muse"]],
                       ["schema": ["version": 1], "serverInfo": ["name": "other"]]] {
            let fixture = try InspectionProcessFixture(script: "read_request\n" + reply(1, ["result": result]))
            assertInspectionFailure(fixture)
            XCTAssertEqual(try fixture.requests.compactMap { $0["method"] as? String }, ["initialize"])
            try fixture.assertStopped()
        }
    }

    func testErrorMissingOrWrongResultCannotBecomeAnEmptyCatalogue() throws {
        for payload: [String: Any] in [[:], ["result": []], ["error": ["code": -32000, "message": "fixture-secret"]],
                                       ["result": catalogue, "error": ["code": -32000, "message": "fixture-secret"]],
                                       ["result": ["providerId": "other", "models": []]]] {
            let fixture = try peer(models: payload)
            assertInspectionFailure(fixture)
            try fixture.assertStopped()
        }
    }

    func testUnsolicitedFutureCatalogueCannotReplaceRequestedCatalogue() throws {
        let unsolicited = try reply(2, ["result": ["providerId": "meta", "models": []]])
        let fixture = try peer(beforeInitialization: unsolicited)
        XCTAssertEqual(try inspect(fixture).models.map(\.id), ["fixture/first", "fixture/second"])
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
        let directory = fixture.home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.executable, to: directory.appendingPathComponent("muse"))
        try FileManager.default.copyItem(at: fixture.executable, to: directory.appendingPathComponent("muse-bin-1.0.0-R1"))
        try Data("1.0.0-R1\n".utf8).write(to: directory.appendingPathComponent(".muse-version"))
        XCTAssertThrowsError(try MuseInspection.inspect(home: fixture.home, environment: fixture.environment)) {
            XCTAssertTrue($0.localizedDescription.contains("signature"))
        }
        XCTAssertFalse(fixture.wasLaunched)
    }

    func testNoiseAndFragmentedRepliesStillProduceTheRequestedCatalogue() throws {
        let fixture = try peer(beforeInitialization: """
        printf '%s\\n' 'not JSON' '[]' '{"jsonrpc":"2.0","method":"notice"}' '{"jsonrpc":"2.0","id":99,"result":{}}'
        """, fragmented: true)
        XCTAssertEqual(try inspect(fixture).models.count, 2)
        try fixture.assertStopped()
    }

    func testMalformedOutputTimesOutAndKillsAnUncooperativePeer() throws {
        let fixture = try InspectionProcessFixture(script: "read_request\nprintf '%s\\n' 'not JSON'", ignoreTermination: true)
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
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        try fixture.assertStopped()
    }

    func testCrashFailsAndFinalCatalogueSurvivesImmediateExit() throws {
        let crashed = try InspectionProcessFixture(script: "read_request\nprintf '%s' 'fixture-secret' >&2\nexit 17")
        assertInspectionFailure(crashed)
        try crashed.assertStopped()
        for _ in 0..<5 {
            let fixture = try peer(afterModels: "exit 0")
            XCTAssertEqual(try inspect(fixture).models.count, 2)
            try fixture.assertStopped()
        }
    }

    func testMissingInstallationAndUnlaunchableExecutable() throws {
        let fixture = try InspectionProcessFixture(script: "exit 1")
        let missing = try MuseInspection.inspect(home: fixture.home, environment: [:])
        XCTAssertNil(missing.executablePath)
        XCTAssertNil(missing.authentication)
        XCTAssertTrue(missing.models.isEmpty)
        XCTAssertThrowsError(try MuseInspection.inspect(executable: fixture.home.appendingPathComponent("missing"),
            installationPath: "/missing", home: fixture.home, environment: fixture.environment))
    }

    private func inspect(_ fixture: InspectionProcessFixture, timeout: TimeInterval = 3) throws -> MuseInspectionResult {
        try MuseInspection.inspect(executable: fixture.executable, installationPath: "/reported/muse", home: fixture.home,
                                   environment: fixture.environment, requestTimeout: timeout, terminationGrace: 0.2)
    }
    private func assertInspectionFailure(_ fixture: InspectionProcessFixture, timeout: TimeInterval = 3,
                                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try inspect(fixture, timeout: timeout), file: file, line: line) {
            XCTAssertTrue($0 is HarnessSetupError, file: file, line: line)
            XCTAssertFalse($0.localizedDescription.contains("fixture-secret"), file: file, line: line)
        }
    }
    private func peer(models: [String: Any]? = nil, beforeInitialization: String = "", afterModels: String = "",
                      fragmented: Bool = false) throws -> InspectionProcessFixture {
        let modelPayload = (models ?? ["result": catalogue]).merging(["jsonrpc": "2.0", "id": 2]) { _, new in new }
        let modelReply: String
        if fragmented {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: modelPayload), as: UTF8.self)
            modelReply = "printf '%s' " + InspectionProcessFixture.quote(String(json.prefix(10))) + "\n" +
                "printf '%s\\n' " + InspectionProcessFixture.quote(String(json.dropFirst(10)))
        } else { modelReply = try InspectionProcessFixture.emit(modelPayload) }
        return try InspectionProcessFixture(script: """
        read_request
        \(beforeInitialization)
        \(reply(1, ["result": initialization]))
        read_request
        read_request
        \(modelReply)
        \(afterModels)
        """)
    }
    private func reply(_ id: Int, _ payload: [String: Any]) throws -> String {
        try InspectionProcessFixture.emit(payload.merging(["jsonrpc": "2.0", "id": id]) { _, new in new })
    }
}
