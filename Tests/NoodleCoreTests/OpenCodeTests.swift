import Foundation
import SQLite3
import XCTest
@testable import NoodleCore

final class OpenCodeTests: XCTestCase {
    func testDiscoveryAndTrustRejectWrappersAndRedirects() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent(".opencode/bin/opencode")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let discovery = HarnessDiscovery(homeDirectory: root, applicationsDirectory: root, executableSearchDirectories: [], environment: [:])
        XCTAssertEqual(discovery.discover(.openCode).executablePath, binary.path)
        XCTAssertThrowsError(try OpenCodeExecutableTrust.executable(at: binary.path, home: root))
        try FileManager.default.removeItem(at: binary)
        try FileManager.default.createSymbolicLink(at: binary, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        XCTAssertThrowsError(try OpenCodeExecutableTrust.executable(at: binary.path, home: root))
        XCTAssertTrue(HarnessProvider.openCode.supportsRestrictedAccess)
        XCTAssertFalse(HarnessProvider.openCode.supportsAccountApps)
    }

    func testV2CatalogueVariantsAndReleaseChannel() throws {
        XCTAssertTrue(OpenCodeProtocol.supportsVersion("2.0.7"))
        XCTAssertFalse(OpenCodeProtocol.supportsVersion("1.2.3"))
        XCTAssertFalse(OpenCodeProtocol.supportsVersion("3.0.0"))
        let data = Data(#"{"data":[{"providerID":"test","id":"model","name":"Model","variants":[{"id":"high"},{"id":"high"},{"id":"bad value"}]},{"providerID":"test","id":"model"},{"providerID":"bad provider","id":"model"},{"providerID":"test","id":"text-only","capabilities":{"tools":false}}]}"#.utf8)
        let models = try OpenCodeProtocol.models(from: data)
        XCTAssertEqual(models.map(\.id), ["test/model"])
        XCTAssertEqual(models[0].supportedEfforts.map(\.id), ["high", "default"])
        XCTAssertEqual(models[0].defaultEffort, "default")
        XCTAssertThrowsError(try OpenCodeProtocol.models(from: Data("[]".utf8)))
        let release = Data(#"{"channel":"latest","name":"cli","distribution":"npm","version":"2.0.7","active":true}"#.utf8)
        XCTAssertEqual(HarnessVersionPolicy.latestVersion(provider: .openCode, data: release), "2.0.7")
        XCTAssertNil(HarnessVersionPolicy.latestVersion(provider: .openCode, data: Data(#"{"tag_name":"v1.9.0"}"#.utf8)))
        XCTAssertNil(HarnessVersionPolicy.compatibilityIssue(provider: .openCode, help: "USAGE\nopencode acp api auth --standalone"))
        XCTAssertNotNil(HarnessVersionPolicy.compatibilityIssue(provider: .openCode, help: "USAGE\nopencode acp auth"))
    }

    func testCatalogueWaitsForRefreshAfterAnInitiallyNonemptySnapshot() throws {
        var elapsed: TimeInterval = 0
        let bundled = Data(#"{"data":[{"providerID":"opencode","id":"old-model"}]}"#.utf8)
        let refreshed = Data(#"{"data":[{"providerID":"opencode","id":"union-alpha","name":"Union Alpha Free","capabilities":{"tools":true}}]}"#.utf8)
        let preferred = Data(#"{"data":{"providerID":"opencode","id":"union-alpha"}}"#.utf8)
        let models = try OpenCodeModelProbe.loadModels(waitForRefresh: true, read: { path in
            if path == "/api/model/default" { return preferred }
            // The initial list stays stable for several seconds before refresh.
            return elapsed < 8 ? bundled : refreshed
        }, now: { elapsed }, sleep: { elapsed += $0 })
        XCTAssertEqual(models.map(\.id), ["opencode/union-alpha"])
        XCTAssertTrue(models[0].isDefault)
        XCTAssertEqual(elapsed, 12)
    }

    func testCatalogueRefreshIsBoundedAndKeepsOfflineSnapshot() throws {
        var elapsed: TimeInterval = 0
        let data = Data(#"{"data":[{"providerID":"test","id":"cached"}]}"#.utf8)
        let models = try OpenCodeModelProbe.loadModels(waitForRefresh: true,
            read: { $0 == "/api/model" ? data : Data(#"{"data":null}"#.utf8) },
            now: { elapsed }, sleep: { elapsed += $0 })
        XCTAssertEqual(models.map(\.id), ["test/cached"])
        XCTAssertEqual(elapsed, 12)
        elapsed = 0
        _ = try OpenCodeModelProbe.loadModels(waitForRefresh: false,
            read: { $0 == "/api/model" ? data : Data(#"{"data":null}"#.utf8) },
            now: { elapsed }, sleep: { elapsed += $0 })
        XCTAssertEqual(elapsed, 0, "Explicit model files do not need a network refresh")
    }

    /// Optional live catalogue read, with no account or model requests.
    func testNativePublicCatalogueIncludesRequestedModel() throws {
        guard let path = ProcessInfo.processInfo.environment["NOODLE_TEST_OPENCODE_EXECUTABLE"],
              let requested = ProcessInfo.processInfo.environment["NOODLE_TEST_OPENCODE_PUBLIC_MODEL"] else {
            throw XCTSkip("Set native executable and public model to check online catalogue discovery")
        }
        let executable = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        try OpenCodeExecutableTrust.verifySignature(executable)
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let layout = AgentStorageLayout(package: root.appendingPathComponent("bot")); try layout.create()
        try OpenCodeStorage.prepareDirectories(workspace: layout.workspace)
        let profile = try RestrictedAgentSandbox.profile(provider: .openCode, workspace: layout.workspace,
            repository: root, home: root, executable: executable, application: layout.workspace, temporary: layout.workspace)
        let environment = OpenCodeStorage.environment(workspace: layout.workspace)
        let probe = try OpenCodeModelProbe(executable: executable, workspace: layout.workspace,
            environment: environment, profile: profile)
        defer { probe.stop() }
        XCTAssertTrue(try probe.models().contains { $0.id == requested })
        probe.stop()
        // A fresh bot must also select the model before sending its first turn.
        let cold = AgentStorageLayout(package: root.appendingPathComponent("cold-bot")); try cold.create()
        try OpenCodeStorage.prepareDirectories(workspace: cold.workspace)
        let coldProfile = try RestrictedAgentSandbox.profile(provider: .openCode, workspace: cold.workspace,
            repository: root, home: root, executable: executable, application: cold.workspace, temporary: cold.workspace)
        let coldModels = try OpenCodeInspection.prepareCatalogue(executable: executable, workspace: cold.workspace,
            environment: OpenCodeStorage.environment(workspace: cold.workspace), profile: coldProfile)
        XCTAssertTrue(coldModels.contains { $0.id == requested })
        let wire = try ACPWireFixture(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"), workspace: cold.workspace,
            arguments: ["-p", coldProfile, executable.path, "acp"],
            environment: OpenCodeStorage.environment(workspace: cold.workspace), requestTimeout: 25)
        defer { wire.stop() }
        _ = try wire.request("initialize", FxProtocol.initializeParameters)
        let session = try wire.request("session/new", ["cwd": cold.workspace.path, "mcpServers": []])
        let id = try XCTUnwrap(session["sessionId"] as? String)
        _ = try wire.request("session/set_config_option", ["sessionId": id, "configId": "model", "value": requested])
    }

    func testOnlyExplicitMatchingMissingSessionPermitsRecovery() {
        let error: [String: Any] = ["code": -32602, "message": "session not found: ses_test", "data": ["sessionId": "ses_test"]]
        XCTAssertTrue(OpenCodeProtocol.missingSession(error, sessionID: "ses_test"))
        XCTAssertFalse(OpenCodeProtocol.missingSession(error, sessionID: "ses_other"))
        XCTAssertFalse(OpenCodeProtocol.missingSession(["code": -32602, "message": "Session not found"], sessionID: "ses_test"))
    }

    func testToolsCannotListenOnNetworkPorts() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let layout = AgentStorageLayout(package: root.appendingPathComponent("bot")); try layout.create()
        try OpenCodeStorage.prepareDirectories(workspace: layout.workspace)
        let profile = try RestrictedAgentSandbox.profile(provider: .openCode, workspace: layout.workspace,
            repository: root, home: root, executable: URL(fileURLWithPath: "/usr/bin/true"),
            application: layout.workspace, temporary: layout.workspace)
        let script = #"""
        require 'socket'
        ['127.0.0.1', '0.0.0.0', '::1', '::'].each do |address|
          begin
            server = TCPServer.new(address, 0)
            server.close
            abort 'tool listener was allowed'
          rescue Errno::EPERM, Errno::EACCES
          end
        end
        puts 'listeners-denied'
        """#
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile, "/usr/bin/ruby", "--disable-gems", "-e", script]
        process.standardOutput = output; process.standardError = output
        process.environment = OpenCodeStorage.environment(workspace: layout.workspace)
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertTrue(text.contains("listeners-denied"), text)
    }

    func testCredentialReadContainsNoConversationsOrExecutableConfiguration() throws {
        let home = try root(); defer { try? FileManager.default.removeItem(at: home) }
        let db = home.appendingPathComponent(".local/share/opencode/opencode.db")
        try FileManager.default.createDirectory(at: db.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sql(db, "CREATE TABLE credential (id TEXT, integration_id TEXT, value TEXT, active INT, time_created INT); CREATE TABLE session (secret TEXT); INSERT INTO session VALUES ('private conversation');")
        try sql(db, #"INSERT INTO credential VALUES ('cred_one','openai','{"type":"key","key":"fixture-key","configuration":{"command":"bad"},"plugin":"bad"}',1,10);"#)
        try sql(db, #"INSERT INTO credential VALUES ('cred_mcp','mcp_0123456789abcdef','{"type":"key","key":"mcp-private-key"}',1,10);"#)
        let rows = try OpenCodeStorage.credentials(home: home)
        XCTAssertEqual(rows.count, 1)
        let value = try XCTUnwrap(rows[0]["value"] as? String)
        XCTAssertTrue(value.contains("fixture-key")); XCTAssertFalse(value.contains("command")); XCTAssertFalse(value.contains("plugin"))
        XCTAssertFalse(String(describing: rows).contains("private conversation"))
        XCTAssertFalse(String(describing: rows).contains("mcp-private-key"))
        let elsewhere = home.appendingPathComponent("redirected.db")
        try FileManager.default.moveItem(at: db, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: db, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try OpenCodeStorage.credentials(home: home))
    }

    /// Opt-in real native protocol test: no user login, external model or billed prompt.
    func testNativeV2RestrictedStorageAndACP() throws {
        guard let path = ProcessInfo.processInfo.environment["NOODLE_TEST_OPENCODE_EXECUTABLE"] else {
            throw XCTSkip("Set NOODLE_TEST_OPENCODE_EXECUTABLE to an official v2 native binary")
        }
        let executable = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        try OpenCodeExecutableTrust.verifySignature(executable)
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let layout = AgentStorageLayout(package: root.appendingPathComponent("bot")); try layout.create()
        // A synthetic ancestor holds unrelated global configuration. The probe
        // must work without gaining content access to these sibling files.
        let foreign = root.appendingPathComponent(".agents/skills/foreign/SKILL.md")
        try FileManager.default.createDirectory(at: foreign.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("---\nname: foreign\ndescription: Private ancestor skill\n---\nPrivate fixture\n".utf8).write(to: foreign)
        try OpenCodeStorage.prepareDirectories(workspace: layout.workspace)
        var environment = OpenCodeStorage.environment(workspace: layout.workspace)
        let skill = layout.workspace.appendingPathComponent(".agents/skills/noodle-probe/SKILL.md")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("---\nname: noodle-probe\ndescription: Noodle workspace fixture\n---\nUse the workspace only.\n".utf8).write(to: skill)
        try Data("Use the Noodle Messenger skill for conversation messages.\n".utf8).write(to: layout.workspace.appendingPathComponent("AGENTS.md"))
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["OPENCODE_DISABLE_MODELS_FETCH"] = "true"
        let models = layout.workspace.appendingPathComponent("models.json")
        try Data("{}".utf8).write(to: models); environment["OPENCODE_MODELS_PATH"] = models.path
        let profile = try RestrictedAgentSandbox.profile(provider: .openCode, workspace: layout.workspace,
            repository: root, home: root, executable: executable, application: layout.workspace, temporary: layout.workspace)
        let credential: [String: Any] = ["id": "cred_fixture", "integration": "openai", "active": 1, "created": 10,
            "value": #"{"type":"key","key":"fixture-only-not-a-real-key"}"#]
        let seeded = try OpenCodeStorage.seed(credentials: [credential], workspace: layout.workspace,
            executable: executable, environment: environment, profile: profile)
        XCTAssertTrue(seeded)
        let db = RestrictedHarnessStorage.home(workspace: layout.workspace).appendingPathComponent(".local/share/opencode/opencode.db")
        // Keep bot-refreshed credentials across restarts, then replace on a new source sign-in.
        try sql(db, #"UPDATE credential SET value='{"type":"key","key":"bot-refreshed"}';"#)
        _ = try OpenCodeStorage.seed(credentials: [credential], workspace: layout.workspace,
            executable: executable, environment: environment, profile: profile)
        XCTAssertTrue(String(describing: try OpenCodeStorage.credentials(home: RestrictedHarnessStorage.home(workspace: layout.workspace))).contains("bot-refreshed"))
        var changed = credential; changed["value"] = #"{"type":"key","key":"new-sign-in"}"#
        _ = try OpenCodeStorage.seed(credentials: [changed], workspace: layout.workspace,
            executable: executable, environment: environment, profile: profile)
        XCTAssertTrue(String(describing: try OpenCodeStorage.credentials(home: RestrictedHarnessStorage.home(workspace: layout.workspace))).contains("new-sign-in"))
        let config = #"{"update":"disable","model":"test/test-model","providers":{"test":{"name":"Test","package":"aisdk:@ai-sdk/openai-compatible","settings":{"apiKey":"fixture","baseURL":"http://127.0.0.1:1/v1"},"models":{"test-model":{"name":"Test","capabilities":{"tools":true,"input":["text"],"output":["text"]},"limit":{"context":100000,"output":10000},"variants":[{"id":"high"}]}}}}}"#
        try Data(config.utf8).write(to: RestrictedHarnessStorage.home(workspace: layout.workspace).appendingPathComponent(".config/opencode/opencode.json"))
        let probe = try OpenCodeModelProbe(executable: executable,
            workspace: layout.workspace, environment: environment, profile: profile)
        defer { probe.stop() }
        XCTAssertTrue(try probe.models().contains { $0.id == "test/test-model" && $0.isDefault && $0.supportedEfforts.contains { $0.id == "high" } })
        var skills = ""
        let deadline = Date().addingTimeInterval(5)
        repeat {
            skills = String(decoding: try probe.get("/api/skill"), as: UTF8.self)
            if skills.contains("noodle-probe") { break }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        XCTAssertTrue(skills.contains("noodle-probe"))
        XCTAssertFalse(skills.contains("Private ancestor skill"))
        probe.stop()
        let wire = try ACPWireFixture(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"), workspace: layout.workspace,
            arguments: ["-p", profile, executable.path, "acp"], environment: environment, requestTimeout: 25)
        defer { wire.stop() }
        XCTAssertEqual(try wire.request("initialize", FxProtocol.initializeParameters)["protocolVersion"] as? Int, 1)
        let session = try wire.request("session/new", ["cwd": layout.workspace.path, "mcpServers": []])
        let id = try XCTUnwrap(session["sessionId"] as? String)
        _ = try wire.request("session/set_config_option", ["sessionId": id, "configId": "model", "value": "test/test-model"])
        _ = try wire.request("session/set_config_option", ["sessionId": id, "configId": "effort", "value": "high"])
        _ = try wire.request("session/load", ["sessionId": id, "cwd": layout.workspace.path, "mcpServers": []])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".local/share/opencode/opencode.db").path))
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-test-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }

    private func sql(_ url: URL, _ query: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw HarnessSetupError("Fixture database failed") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK else { throw HarnessSetupError("Fixture SQL failed") }
    }
}
