import XCTest
@testable import NoodleCore

final class MuseTests: XCTestCase {
    func testTurnFailuresAndRetriesAreVisibleWithoutInventedStatus() {
        let failure = MuseProtocol.turnFailureDetail(["terminal": "failed", "error": ["kind": "projectionError", "message": "Incompatible history", "retryable": false]])
        XCTAssertTrue(failure.contains("Incompatible history"))
        XCTAssertTrue(failure.contains("Retry Startup"))
        XCTAssertTrue(MuseProtocol.turnFailureDetail(["reason": "Cancelled"]).contains("Cancelled"))
        XCTAssertNil(MuseProtocol.retryDetail([:]))
        XCTAssertNil(MuseProtocol.retryDetail(["nextAttempt": 2, "maxAttempts": 1, "retryDelayMs": -1]))
        XCTAssertEqual(MuseProtocol.retryDetail(["nextAttempt": 2, "maxAttempts": 10, "retryDelayMs": 60000, "reason": "HTTP 503"]), "Muse: HTTP 503. Retry 2/10 scheduled in 60s.")
    }
    func testSavedAuthenticationFormatsAndUnknownStates() throws {
        func status(_ json: String) -> HarnessAuthenticationStatus {
            MuseAuthentication.status(data: Data(json.utf8))
        }
        XCTAssertEqual(status(#"{"providers":{"meta":{"mechanism":"oauth","storage":"keychain"}}}"#), .authenticated)
        XCTAssertEqual(status(#"{"providers":{"meta":{"mechanism":"api_key","storage":"keychain"}}}"#), .authenticated)
        XCTAssertEqual(status(#"{"providers":{"meta":{"mechanism":"oauth","access_token":"fixture","expires_at":1}}}"#), .authenticated)
        XCTAssertEqual(status(#"{"providers":{"meta":{"mechanism":"oauth","refresh_token":"fixture"}}}"#), .authenticated)
        XCTAssertEqual(status(#"{"providers":{"meta":{"mechanism":"api_key","storage":"file","api_key":"fixture"}}}"#), .authenticated)
        XCTAssertEqual(status("{}"), .unauthenticated)
        XCTAssertEqual(status(#"{"providers":{"other":{}}}"#), .unauthenticated)
        for json in ["bad", "[]", #"{"providers":[]}"#,
                     #"{"providers":{"meta":null}}"#,
                     #"{"providers":{"meta":{"mechanism":"future","storage":"keychain"}}}"#,
                     #"{"providers":{"meta":{"mechanism":"oauth","storage":"future","access_token":"fixture"}}}"#,
                     #"{"providers":{"meta":{"mechanism":"oauth","access_token":" "}}}"#] {
            XCTAssertEqual(status(json), .managedExternally)
        }
    }

    func testAuthenticationReadIsBoundedAndUsesRuntimeConfiguration() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let folder = root.appendingPathComponent(".config/muse")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("auth.json")
        func inspect(_ environment: [String: String] = [:]) -> HarnessAuthenticationStatus {
            MuseAuthentication.inspect(home: root, environment: environment)
        }
        XCTAssertEqual(inspect(), .unauthenticated)
        let fixture = Data(#"{"providers":{"meta":{"mechanism":"oauth","storage":"keychain"}}}"#.utf8)
        try fixture.write(to: file)
        XCTAssertEqual(inspect(), .authenticated)
        XCTAssertEqual(inspect(["XDG_CONFIG_HOME": root.appendingPathComponent("other").path]), .unauthenticated)
        XCTAssertEqual(inspect(["XDG_CONFIG_HOME": "relative"]), .authenticated)
        try Data(repeating: 32, count: 1_048_577).write(to: file)
        XCTAssertEqual(inspect(), .managedExternally)
        try fm.removeItem(at: file)
        try fm.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertEqual(inspect(), .managedExternally)
        try fm.removeItem(at: file)
        let target = root.appendingPathComponent("fixture.json")
        try fixture.write(to: target)
        try fm.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertEqual(inspect(), .managedExternally)
        XCTAssertEqual(inspect(["META_API_KEY": "fixture"]), .authenticated)
        XCTAssertEqual(inspect(["META_API_KEY": " "]), .managedExternally)
    }

    func testInspectionExportsStatusOnlyAndDecodesOldResults() throws {
        let result = MuseInspectionResult(executablePath: "/fixture/muse", models: [], authentication: .authenticated)
        let data = try JSONEncoder().encode(result)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["executablePath", "models", "authentication"])
        XCTAssertEqual(try JSONDecoder().decode(MuseInspectionResult.self, from: data).authentication, .authenticated)
        XCTAssertNil(try JSONDecoder().decode(MuseInspectionResult.self, from: Data(#"{"models":[]}"#.utf8)).authentication)
    }

    func testApprovalsAreOnceOnlyAndBoundToSessionAndStage() throws {
        let params: [String: Any] = ["sessionId": "s", "approvalId": "a",
            "currentRequirementId": ["approvalId": "a", "sourceIndex": 42],
            "availableChoices": [["choiceId": "persistent", "decision": "approvedForSession", "scope": "session"],
                                 ["choiceId": "once", "decision": "approved", "scope": "once"]]]
        let decision = try XCTUnwrap(MuseProtocol.approvalParameters(params, sessionID: "s", extendedAccess: true))
        XCTAssertEqual(decision["choiceId"] as? String, "once")
        XCTAssertEqual((decision["requirementId"] as? [String: Any])?["sourceIndex"] as? Int, 42)
        XCTAssertNil(MuseProtocol.approvalParameters(params, sessionID: "other", extendedAccess: true))
        XCTAssertNil(MuseProtocol.approvalParameters(params, sessionID: "s", extendedAccess: false))
        XCTAssertEqual(MuseProtocol.approvalParameters(params, sessionID: "s", extendedAccess: false,
                                                       restrictedAccess: true)?["choiceId"] as? String, "once")
        XCTAssertNil(MuseProtocol.approvalParameters(params, sessionID: "other", extendedAccess: false, restrictedAccess: true))
        var bad = params; bad["currentRequirementId"] = ["approvalId": "other", "sourceIndex": 42]
        XCTAssertNil(MuseProtocol.approvalParameters(bad, sessionID: "s", extendedAccess: true))
        XCTAssertNil(MuseProtocol.approvalParameters(bad, sessionID: "s", extendedAccess: false, restrictedAccess: true))
        bad = params; bad["availableChoices"] = [["choiceId": "persistent", "decision": "approvedForSession", "scope": "session"]]
        XCTAssertNil(MuseProtocol.approvalParameters(bad, sessionID: "s", extendedAccess: true))
        XCTAssertNil(MuseProtocol.approvalParameters(bad, sessionID: "s", extendedAccess: false, restrictedAccess: true))
    }
    func testVersionPointerAndUpdateRevisionOrdering() {
        for version in ["1.0.3-R2198.1", "1.0.3-R2198"] { XCTAssertTrue(MuseExecutableTrust.validVersion(version)) }
        for version in ["../muse", "1.0.3", "1.0.3-R1/sh", "1.0.3-R1\n", "1.0.3-R1;echo hi"] {
            XCTAssertFalse(MuseExecutableTrust.validVersion(version))
        }
        XCTAssertLessThan(HarnessVersion("1.0.3-R9")!, HarnessVersion("1.0.3-R10")!)
        XCTAssertEqual(HarnessVersionPolicy.latestVersion(provider: .muse,
            data: Data(#"{"channel":"muse-stable","state":"public","version":"1.0.3-R2198.1"}"#.utf8)), "1.0.3-R2198.1")
        XCTAssertNil(HarnessVersionPolicy.latestVersion(provider: .muse, data: Data(#"{"version":"1.0.3-R1"}"#.utf8)))
    }
    func testCommandIDsAreUUIDv7AndTurnInputIsMSP() throws {
        let id = MuseProtocol.commandID(now: Date(timeIntervalSince1970: 1234))
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertEqual(Array(id)[14], "7")
        XCTAssertTrue(["8", "9", "a", "b"].contains(String(Array(id)[19])))
        XCTAssertNotEqual(id, MuseProtocol.commandID(now: Date(timeIntervalSince1970: 1234)))
        let params = MuseProtocol.turnParameters(sessionID: "session", commandID: id, text: "wake", effort: "high")
        XCTAssertEqual(params["ifBusy"] as? String, "queue")
        XCTAssertEqual(params["reasoningEffort"] as? String, "high")
        XCTAssertEqual((params["input"] as? [[String: String]])?.first, ["type": "text", "text": "wake"])
    }
    func testModelCatalogueKeepsProviderDescriptionsAndEfforts() throws {
        let rows: [[String: Any]] = [
            ["providerId": "meta", "modelId": "muse-spark-1.3", "displayLabel": "Muse Spark", "isDefault": false],
            ["providerId": "meta", "modelId": "muse-spark-1.3-contributor", "description": "Content may be used for improvement.", "isDefault": true],
            ["providerId": "other", "modelId": "wrong"], ["providerId": "meta", "modelId": "muse-spark-1.3"]]
        let models = try MuseProtocol.models(["providerId": "meta", "models": rows])
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0].displayName, "Muse Spark")
        XCTAssertEqual(models[1].description, "Content may be used for improvement.")
        XCTAssertTrue(models[1].isDefault)
        XCTAssertEqual(models[0].supportedEfforts.map(\.id), MuseProtocol.efforts)
        XCTAssertThrowsError(try MuseProtocol.models(["providerId": "echo", "models": []]))
    }
    func testInitializationRequiresMSPV1AndPersistentRuntime() throws {
        let result: [String: Any] = ["serverInfo": ["name": "muse"], "schema": ["version": 1], "sessionDurability": "durable"]
        XCTAssertNoThrow(try MuseProtocol.validateInitialization(result, durable: true))
        var invalid = result
        invalid["schema"] = ["version": 2]
        XCTAssertThrowsError(try MuseProtocol.validateInitialization(invalid, durable: true))
        invalid = result; invalid["sessionDurability"] = "ephemeral"
        XCTAssertThrowsError(try MuseProtocol.validateInitialization(invalid, durable: true))
        XCTAssertNoThrow(try MuseProtocol.validateInitialization(invalid, durable: false))
    }
    func testDiscoveryAndNativeTrustRejectUnsignedAndRedirectedBinaries() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("muse-trust-\(UUID())").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: root) }
        let directory = root.appendingPathComponent(".local/bin")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let launcher = directory.appendingPathComponent("muse")
        try Data("#!/bin/sh\nexit 1".utf8).write(to: launcher)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        let pointer = directory.appendingPathComponent(".muse-version")
        try Data("1.0.3-R2198.1\n".utf8).write(to: pointer)
        let binary = directory.appendingPathComponent("muse-bin-1.0.3-R2198.1")
        try Data("not a signed binary".utf8).write(to: binary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let discovery = HarnessDiscovery(homeDirectory: root, applicationsDirectory: root, executableSearchDirectories: [], environment: [:])
        XCTAssertEqual(discovery.discover(.muse).executablePath, launcher.path)
        XCTAssertEqual(HarnessProvider.muse.displayName, "Muse Code")
        XCTAssertThrowsError(try MuseExecutableTrust.executable(at: launcher.path, home: root)) {
            XCTAssertTrue($0.localizedDescription.contains("Meta signature could not be verified"))
        }
        try fm.removeItem(at: binary)
        try fm.createSymbolicLink(at: binary, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        XCTAssertThrowsError(try MuseExecutableTrust.executable(at: launcher.path, home: root)) {
            XCTAssertTrue($0.localizedDescription.contains("missing or redirected"))
        }
        try fm.removeItem(at: pointer)
        try fm.createSymbolicLink(at: pointer, withDestinationURL: launcher)
        XCTAssertThrowsError(try MuseExecutableTrust.executable(at: launcher.path, home: root))
    }
    func testInstalledMuseReadOnlyInspection() throws {
        guard ProcessInfo.processInfo.environment["NOODLE_TEST_MUSE_INSPECTION"] == "1" else {
            throw XCTSkip("Opt-in signed Muse installation/model/saved-login probe; no sessions, prompts or Keychain reads.")
        }
        let result = try MuseInspection.inspect(home: HarnessStorage.userHome, environment: ProcessInfo.processInfo.environment)
        XCTAssertNotNil(result.executablePath)
        XCTAssertFalse(result.models.isEmpty)
        if ProcessInfo.processInfo.environment["NOODLE_TEST_MUSE_EXPECT_SIGNED_IN"] == "1" {
            XCTAssertEqual(result.authentication, .authenticated)
        }
    }
}
